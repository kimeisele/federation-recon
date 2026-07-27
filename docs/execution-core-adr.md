# ADR — Execution Core S0: Bedrohungsmodell, Vertrauensgrenzen, Ausführungsprotokoll

**Status:** Entwurf. Kein Code, keine Implementierung, bis dieser Entwurf kritisch geprüft ist.
**Anlass:** #104 — `acceptance_commands` waren beliebige Codeausführung mit den Rechten des Owners. Dreimal real gelaufen.
**Vorgabe:** Owner, 2026-07-27, nach Konsultation Sol 5.6 und Kimi K3.

---

## 1. Was tatsächlich passiert ist

Drei echte Builder-Läufe am 2026-07-27, DeepSeek über `jcode`, auf dem persönlichen Rechner des Owners, als der Owner, ohne Isolation.

| Lauf | Verdikt | Was er zeigte |
|---|---|---|
| `wo-98-1` | accepted | Die Ausführungsebene verwarf die geprüfte Arbeit (#99) |
| `wo-98-2` | rejected | Werkzeug schrieb in ein nicht erlaubtes Verzeichnis; Builder meldete `completed` (#101) |
| `wo-98-3` | accepted | Arbeit war inhaltlich falsch und schädlich; Abnahme war zirkulär (#103) |

Und quer über alle drei, wörtlich in `operator/run.sh`:

```bash
(cd "$WORKTREE" && eval "$cmd") >/dev/null 2>&1
```

Ein Abnahmekommando durfte auf eine Datei zeigen, die der Builder erzeugt hat. Nachgeprüft für `wo-98-3`: `git cat-file -e <base_sha>:scripts/test/gate-cleanup.bats` → existierte nicht. **Der Builder schrieb die Datei, der Orchestrator führte sie mit Owner-Rechten aus, mit unterdrückter Ausgabe.**

## 2. Bedrohungsmodell

### Was als nicht vertrauenswürdig gilt

- **Das Builder-Modell.** Nicht weil es bösartig ist, sondern weil sein Verhalten weder spezifiziert noch reproduzierbar ist. `wo-98-2` hat unaufgefordert Dateien außerhalb der Aufgabe erzeugt und das nicht gemeldet.
- **Die Werkzeugkette um das Modell.** `jcode` ist Drittsoftware mit eigenem Scratch-Verhalten, eigenen Update-Prüfungen und eigener Netzaktivität. Sie hat nachweislich außerhalb ihres `-C`-Verzeichnisses geschrieben.
- **Jeder Artefakt, den der Builder erzeugt** — Patch, Testdateien, Ausgaben. Insbesondere alles, was danach *ausgeführt* wird.

### Was als vertrauenswürdig gilt

- **Der Operator** (die Sitzung, die Aufträge schreibt und Abnahmen fährt). Läuft auf dem Host, mit vollem Zugriff.
- **Das Repository bei `base_sha`** und die dort bereits vorhandenen Tests.
- **Der Owner.**

### Was diese Architektur ausdrücklich NICHT schützt

Dieser Abschnitt steht bewusst vor den Maßnahmen, damit das Dokument nicht mehr Sicherheit verkauft, als es liefert.

1. **Ein falscher Auftrag des Operators.** `wo-98-3` bestand jede mechanische Prüfung und war trotzdem falsche, schädliche Arbeit. Ursache war die Auftragsgestaltung, nicht das Modell. **Kein Sandkasten behebt das.**
2. **Ein kompromittierter oder irrender Operator.** Der Operator läuft mit Host-Rechten und kann nicht sich selbst einsperren.
3. **Semantische Korrektheit.** Ein Pfad-Gate sagt *wo*, ein Exit-Code sagt *fertig*. Keins sagt *richtig*. Das bleibt menschliche Lektüre.
4. **Kompromittierung des Modellanbieters.** Der Builder braucht Netz zu genau einem Endpunkt; das ist ein Loch, das nicht geschlossen, nur verengt werden kann.

## 3. Vertrauensgrenzen

```
┌─ HOST (vertraut) ─────────────────────────────────────┐
│  Operator-Sitzung, Repository, Owner-Secrets, git      │
│  Schreibt Aufträge, liest Patches, entscheidet Merge   │
│                                                        │
│  ┌─ VM, wegwerfbar, keine Host-Mounts ──────────────┐ │
│  │  ┌─ SANDBOX A: BAU ──────────────────────────┐   │ │
│  │  │  Eingang: Base-Archiv, Work Order         │   │ │
│  │  │  Läuft: Builder + Modell-Werkzeugkette    │   │ │
│  │  │  Ausgang: NUR ein Patch                   │   │ │
│  │  │  Netz: nur Modell-Endpunkt, sonst zu      │   │ │
│  │  └───────────────────────────────────────────┘   │ │
│  │  ┌─ SANDBOX B: PRÜFUNG (frisch) ─────────────┐   │ │
│  │  │  Eingang: Base-Archiv, Patch, Orakel      │   │ │
│  │  │  Wendet den Patch selbst an               │   │ │
│  │  │  Führt NUR vorbestehende Orakel aus       │   │ │
│  │  │  Netz: zu                                 │   │ │
│  │  │  Ausgang: NUR strukturiertes Ergebnis     │   │ │
│  │  └───────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────┘ │
│  Logs werden vom HOST geschrieben, nicht vom Sandkasten│
└────────────────────────────────────────────────────────┘
```

**Die entscheidende Trennung ist A ≠ B.** Wer baut, prüft nicht. Der Prüfer wendet den Patch selbst an und führt ausschließlich Orakel aus, die bei `base_sha` existierten. Damit sterben #103 und #104 gleichzeitig, weil der Builder kein Kommando mehr benennen kann, das ihn prüft.

## 4. Ausführungsprotokoll

1. Operator schreibt Work Order. Orakel-Pfade **müssen** bei `base_sha` existieren — mechanisch mit `git cat-file -e` geprüft, sonst Zurückweisung.
2. Host erzeugt ein Base-Archiv bei `base_sha`. Keine Mounts, kein Worktree auf dem Host.
3. **Sandbox A** erhält Archiv und Work Order, baut, gibt **einen Patch** zurück. Sonst nichts.
4. Host prüft den Patch strukturell: Pfade, Zeilenobergrenze, Nebenwirkungs-Zusammenfassung (gelöschte Dateien, neue Traps, Netzaufrufe, neue ausführbare Dateien).
5. **Sandbox B**, frisch, erhält Archiv + Patch + Orakel. Wendet an, führt aus, gibt ein typisiertes Ergebnis zurück. Keine Shell-Strings als Vertrag.
6. Host fällt das Verdikt und schreibt das Protokoll.
7. Mensch liest den Patch. Ohne das kein Merge.

## 5. Salvage-Grenze

**Behalten:**
- Work-Order-Modell und `schemas/work-order.json`
- Ereignis- und Evidenzmodell (`events.jsonl`, `result.json`, `changes.patch`)
- Patch-als-Ausgabe
- Mutationstest-Disziplin und die unabhängige Prüfung von Behauptungen
- `builder_claim_contradicted` als Feld

**Verwerfen oder in Quarantäne:**
- Shell als Sicherheitskernel
- Host-Worktrees als Ausführungsraum
- `eval` und freie Abnahmekommandos
- `allowed_paths` als angebliche Grenze — bleibt als **Policy-Lint**, verliert den Namen „Grenze"
- Jede Ausführung mit Host-Identität, Host-Secrets oder Host-Dateisystem

## 6. Reihenfolge und Abnahmekriterien

| | Inhalt | Abnahme |
|---|---|---|
| **S0** | dieses Dokument | kritisch geprüft, nicht von mir |
| **S1** | Sandbox-Canary | Ein absichtlich bösartiger Testbauer versucht: Host-`$HOME` lesen, `~/.config/secrets/env` lesen, ins Netz außerhalb des Modell-Endpunkts, in fremde Pfade schreiben, unbegrenzt Prozesse forken. **Jeder Versuch muss technisch scheitern**, nicht durch Nachschau auffallen. |
| **S2** | Builder erzeugt nur einen Patch | Sandbox A gibt nichts außer einem Patch zurück; nachgewiesen durch einen Bauer, der andere Ausgaben versucht |
| **S3** | unabhängige Prüfung | Sandbox B wendet Base+Patch an und führt nur vorbestehende Orakel aus; ein Patch, der ein Orakel verändert, wird zurückgewiesen |
| **S4** | Dispatcher wieder anschließen | erst nach S1–S3 |

**Kein echtes Modell vor bestandener S1–S3-Abnahme.**

## 7. Substrat

Lima im Plain Mode auf macOS liefert die VM-Grenze ohne automatische Host-Mounts. gVisor/`runsc` rootless darin für den Builder-Prozess. Beides ist für nicht vertrauenswürdige Workloads gebaut, im Gegensatz zu Shell-Wrappern.

**Nicht `sandbox-exec`.** Es wurde geprüft und funktioniert, aber es ist ein macOS-Profil um einen Prozess auf dem Host — kein Ersatz für eine Maschinengrenze, und es hätte #104 nicht verhindert, weil die Abnahme außerhalb davon lief.

## 8. Vom Owner angenommenes Risiko

Der Owner hat die Rotation der API-Schlüssel **ausdrücklich abgelehnt** (2026-07-27).

Faktenlage, damit die Entscheidung auf Tatsachen ruht und nicht auf Beruhigung:

- `~/.config/secrets/env` (chmod 600) war für builder-geschriebenen Code lesbar, der dreimal mit Owner-Rechten ausgeführt wurde.
- Ob gelesen wurde, ist **unbekannt und nicht mehr feststellbar**: die Ausgabe der Abnahmekommandos wurde nach `/dev/null` verworfen.
- Host-Prüfung ergab keine Auffälligkeiten: keine neuen LaunchAgents, kein crontab, `~/.ssh` unberührt, Shell-Konfiguration seit dem 26.7. unverändert.
- Netzverkehr wurde nicht aufgezeichnet und kann nicht rekonstruiert werden.

Das Risiko ist damit **nicht widerlegt, sondern angenommen.** Diese Zeile existiert, damit die Entscheidung datiert und zurechenbar ist.

## 9. Wo ich der Vorgabe widerspreche

**Die Trennung Bau/Prüfung ist wertvoller als die VM und sollte in S1, nicht S3.** Sie beseitigt die Klasse „Builder schreibt sein eigenes Orakel" ohne jede Infrastruktur. Sie ist allerdings **notwendig und nicht hinreichend**: auch ein vorbestehendes Orakel führt nach dem Anwenden des Patches builder-geschriebenen Code aus. Die VM ist das, was diese Ausführung überhaupt zulässig macht. Beide werden gebraucht; die Reihenfolge in der Tabelle bleibt deshalb wie vorgegeben, aber die Begründung sollte lauten: *S1 macht Ausführung erlaubt, S3 macht sie aussagekräftig.*

**Der Netzzugang des Builders ist das verbleibende Loch.** „Netzwerk standardmäßig aus" ist für den Bauschritt nicht durchhaltbar — der Builder *ist* ein Modellaufruf. Realistisch: Egress-Allowlist auf genau einen Host, eigener niedrig privilegierter Schlüssel, und die Annahme, dass der Modellanbieter den Repositoryinhalt sieht. Das ist keine Lösung, sondern eine benannte Restgefahr.

**Was hier nicht steht, ist Absicht:** kein Zeitplan. Die drei Läufe haben gezeigt, dass jede Schicht beim ersten echten Kontakt einen Defekt offenbart. Ein Datum wäre eine Behauptung über Arbeit, die noch niemand gesehen hat.
