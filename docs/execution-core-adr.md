# ADR — Execution Core S0: Bedrohungsmodell, Vertrauensgrenzen, Ausführungsprotokoll

**Status:** Entwurf, Revision 3. Kein Code, bis die Go/No-Go-Kriterien in §11 erfüllt sind.
**Anlass:** #104 — `acceptance_commands` waren beliebige Codeausführung mit den Rechten des Owners. Dreimal real gelaufen.
**Revision 3:** Nach REQUEST CHANGES. Die TCB war falsch durch Auslassung, der Verifier konnte sein eigenes Urteil fälschen, der Launcher glaubte Selbstauskünfte, und der Work Order durfte seine eigenen Grenzen setzen. Sechs Bestandteile wurden als Zeremonie gestrichen (§14) — das Dokument ist deshalb trotzdem nicht kürzer (247 gegen 236 Zeilen), weil die vollständige TCB, die Messliste und die Go/No-Go-Kriterien mehr Platz brauchen als das Gestrichene. Ich hatte „kürzer" behauptet, ohne zu zählen.

---

## 1. Was tatsächlich passiert ist

Drei echte Builder-Läufe am 2026-07-27, DeepSeek über `jcode`, auf dem persönlichen Rechner des Owners, als der Owner, ohne Isolation.

| Lauf | Verdikt | Was er zeigte |
|---|---|---|
| `wo-98-1` | accepted | Die Ausführungsebene verwarf die geprüfte Arbeit (#99) |
| `wo-98-2` | rejected | Werkzeug schrieb außerhalb der erlaubten Pfade; Builder meldete `completed` (#101) |
| `wo-98-3` | accepted | Arbeit war inhaltlich falsch und schädlich; Abnahme war zirkulär (#103) |

Wörtlich in `operator/run.sh`:

```bash
(cd "$WORKTREE" && eval "$cmd") >/dev/null 2>&1
```

Ein Abnahmekommando durfte auf eine Datei zeigen, die der Builder erzeugt hat. Nachgeprüft: `git cat-file -e <base_sha>:scripts/test/gate-cleanup.bats` → existierte nicht. **Der Builder schrieb die Datei, der Orchestrator führte sie mit Owner-Rechten aus, mit unterdrückter Ausgabe.**

---

## 2. Vertrauen

### 2.1 Trusted Computing Base — vollständig

> Eine TCB, die man zu klein angibt, ist eine TCB, die man nicht prüft.

1. **Der Owner**
2. **Der Launcher** — winzig, deterministisch, kein Modell, klein genug zum Ganzlesen
3. **Der Hypervisor**
4. **Das Host-Betriebssystem**
5. **Das VM-Basisimage**
6. **Der Broker** — hält das Credential und erzwingt Grenzen, gehört also hierher
7. **Die Verifier-Logik in der Prüf-VM** — der Supervisor-Prozess, nicht die geprüfte Nutzlast
8. **Die Launcher-Policy-Datei** — sie legt die Grenzen fest

Revision 2 nannte nur 1–3. Das verkleinerte die TCB nicht, es verbarg sie.

### 2.2 Nicht vertrauenswürdig

Der LLM-Operator · der Builder und seine Werkzeugkette · das Repository einschließlich `base_sha` · die Tests im Repository · der Patch · **die Nutzlast in der Prüf-VM** · jede Ausgabe eines Laufs.

### 2.3 Was daraus folgt

Der Operator darf Aufträge **vorschlagen** und Ergebnisse **lesen**. Er führt nicht aus, sperrt nicht ein, gibt nicht frei.

**Unbequeme Folge:** Was der Operator heute „Abnahme" nennt — Mutationsläufe, Gate-Läufe, Vergleiche — sind **Behauptungen, keine Feststellungen**. Evidenz entsteht erst dort, wo der Launcher unabhängig misst.

### 2.4 Dieses Dokument ist untrusted output

Vom Operator geschrieben, nach §2.2 also nicht vertrauenswürdig. Es braucht Prüfung durch jemand anderen. Das ist die einzige mit §2.1 verträgliche Behandlung.

### 2.5 Was diese Architektur NICHT schützt

1. **Ein falscher Auftrag.** `wo-98-3` bestand jede mechanische Prüfung und war schädlich. **Kein Sandkasten behebt das.**
2. **Semantische Korrektheit.** Bleibt menschliche Lektüre durch den Owner.
3. **Eine gebrochene TCB.** Wer Launcher, Hypervisor, Host-OS, Image, Broker oder Policy bricht, hat alles.
4. **Den Modellanbieter.** Er sieht, was der Broker sendet.

---

## 3. Ausführung

**Ein VM-Typ, ein Launcher-Pfad, zwei Läufe mit verschiedenen Eingaben.** Revision 2 beschrieb VM A und VM B als verschiedene Architekturen; das war Zeremonie und verdoppelte die zu prüfende Oberfläche.

```
TCB:  Owner · Launcher · Hypervisor · Host-OS · Basisimage · Broker · Verifier-Supervisor · Policy
        │
        │ startet, begrenzt, misst, sammelt ein, zerstört
        ▼
   ┌─ Lauf 1: BAU ─────────────┐     ┌─ Lauf 2: PRÜFUNG ─────────────────┐
   │ Eingang: Base-Archiv,      │     │ Eingang: Base-Archiv, Envelope,   │
   │          Work Order        │     │          Acceptance Bundle (ro)   │
   │ Netz: keins, kein DNS,     │     │ Netz: keins                       │
   │       kein Schluessel      │     │                                   │
   │ Modell: nur ueber Broker   │     │ SUPERVISOR (privilegiert):        │
   │ Ausgang: Output Envelope   │     │   wendet Patch an, haengt Bundle  │
   └────────────────────────────┘     │   ro ein, fuehrt Pruefungen aus,  │
                                       │   schreibt das Ergebnis           │
                                       │ NUTZLAST (unprivilegiert):        │
                                       │   gepatchter Code und seine Tests │
                                       │   kann Ergebnis und Bundle NICHT  │
                                       │   schreiben                       │
                                       └───────────────────────────────────┘
```

**Der Split im Prüflauf ist tragend.** Eine frische VM tötet Persistenz *zwischen* Läufen, nicht Manipulation *innerhalb* eines Laufs. Ohne Rechtetrennung könnte die geprüfte Nutzlast ihr eigenes Urteil schreiben — strukturell dasselbe wie ein Audit-Log, das der auditierte Prozessbaum führt.

---

## 4. Was der Launcher unabhängig misst

Nichts Verdikt-Relevantes darf aus einer VM stammen, außer über den Supervisor-Kanal des Prüflaufs.

| Messgröße | Quelle |
|---|---|
| Image-Digests beider Läufe | Launcher |
| Bundle-Digest | Launcher |
| Patch-Hash und Bytegröße | Launcher |
| Envelope-Bytegröße | Launcher |
| `run_id`-Bindung über alle Artefakte | Launcher |
| Wanduhr Start/Ende | Launcher |
| VM-Exit- und Terminierungsursache | Hypervisor |
| Tatsächliche Anwendung jeder Grenze aus §6 | Launcher |

**Fehlende Evidenz ist Ablehnung.** „Nicht gemessen" und „eingehalten" dürfen nie dasselbe Ergebnis haben.

---

## 5. Der Host interpretiert nichts

Der Host darf am Envelope ausschließlich: **Bytegröße prüfen · Hash bilden · speichern · weiterreichen.**

Kein Parsen, kein `git apply`, keine Pfadprüfung, keine Nebenwirkungsanalyse. Alles davon gehört in den Prüflauf.

**`allowed_paths` entfällt vollständig** — auch als „Policy-Lint". Es ist unter zwei Namen zweimal gescheitert. Das Acceptance Bundle und die VM-Grenze machen es überflüssig, und ein Lint, der wie eine Grenze klingt, wird wie eine benutzt.

---

## 6. Grenzen — aus der Policy, nicht aus dem Auftrag

Die Grenzen stehen in der **Launcher-Policy**. Ein Work Order darf **engere** Grenzen erbitten, niemals lockerere setzen. Revision 2 ließ den untrusted Operator seine eigene Käfiggröße wählen.

CPU · RAM · PIDs · Disk · Laufzeit · Patchgröße · Envelope-Größe · Modellaufrufe.

Überschreitung oder fehlende Evidenz: **reject und VM-Zerstörung.**

**Neustarts entfallen als Konzept.** Läufe sind wegwerfbar und einmalig. Ein gescheiterter Lauf wird abgelehnt, nicht wiederholt.

---

## 7. Output Envelope

Genau eine begrenzte Struktur verlässt den Baulauf: `patch` · `exit_status` · `stdout`/`stderr` (untrusted, größenbegrenzt, markiert abgeschnitten) · `run_id`.

Image- und Werkzeug-Digests stehen **nicht** darin — der Launcher misst sie selbst (§4). Alles außerhalb der Struktur wird verworfen; ein Lauf, der mehr zurückgeben will, ist rejected.

Das Ergebnis des Prüflaufs liegt an einem Pfad, den **nur der Supervisor-Benutzer** beschreiben kann.

---

## 8. Acceptance Bundle

Vorbestehende Repo-Tests sind **keine vertrauenswürdigen Orakel.** Ein Patch kann eine Testdatei unberührt lassen und sie trotzdem neutralisieren — über einen Helper, den sie sourced, über Konfiguration, über eine Abhängigkeit, über Fixtures.

Das Bundle ist ein eigenes, unveränderliches Artefakt **außerhalb des Patch-Baums**, selbstgenügsam samt Helfern und Fixtures, schreibgeschützt eingehängt **nach** dem Anwenden des Patches, Digest vom Launcher erfasst. Repo-Tests dürfen ergänzend laufen, nie allein entscheiden.

---

## 9. Broker

Auf dem Host, **in der TCB**, klein genug zum Ganzlesen. Typisiertes Protokoll · Größenlimits · Aufrufzähler · kurzlebiges Credential · **Append-only-Protokoll jedes Anfrage- und Antwort-Digests**.

Der Baulauf hat kein Internet, kein DNS, keinen Schlüssel. Er sieht das Credential nie.

**SHOULD:** Redaktionsdurchlauf, der bekannte Geheimnisformate vor dem Weiterleiten entfernt. Bestenfalls-Maßnahme, ausdrücklich als solche dokumentiert.

**Restgefahr:** Der Modellanbieter sieht, was der Broker sendet. Keine Lücke im Entwurf, sondern die Natur eines externen Modells.

---

## 10. Substrat

**Es ist keine Entscheidung getroffen.** Zu erfüllende Eigenschaften:

1. Wegwerfbare VM-Grenze ohne Host-Mounts
2. Kein Netz — kein Internet, kein DNS, keine Erreichbarkeit des Hosts
3. Durchsetzbare Ressourcengrenzen, deren Fehlkonfiguration ein **Fehler** ist und kein stilles Weiterlaufen
4. Rootless, unprivilegiert
5. Reproduzierbar identifizierbares Image (Digest)

**Ein korrekt konfigurierter wegwerfbarer VM genügt. gVisor entfällt.** Es verteidigt den Gastkern einer Maschine, die anschließend gelöscht wird, und sein rootless-Modus bringt genau die stillen Fehlermodi mit, die dieser Entwurf sonst ausschließt — kein Netstack, ignorierte cgroup-Fehler.

Lima Plain Mode ist **Kandidat, per Canary zu prüfen**: statische Forwards und `host.lima.internal` bleiben möglich und müssen nachweislich gesperrt sein. `sandbox-exec` ist ausgeschlossen — ein Profil um einen Host-Prozess, das #104 nicht verhindert hätte.

---

## 11. Go/No-Go vor S1

Jedes Kriterium ist durch **Lesen** prüfbar, nicht durch Vertrauen in einen Lauf.

1. §2.1 enthält die vollständige TCB und ist von jemand anderem als dem Operator geprüft — mit datierter schriftlicher Freigabe des Owners.
2. Das Work-Order-Schema kann gelockerte Grenzen **strukturell nicht ausdrücken**. Dazu eine Datei bösartiger Testvektoren, die der Validator zurückweisen muss. Der Validator ist rein, deterministisch, ohne Shell-Aufruf.
3. Die Evidenzliste aus §4 liegt als feste Checkliste vor, mit „fehlend = reject" **pro Punkt**.
4. Der Supervisor/Nutzlast-Split ist spezifiziert: welcher Benutzer was ausführt, welche Pfade jeder beschreiben darf, wo das Ergebnis liegt. Eine Seite.
5. Ein Substrat-Kandidat ist gewählt, und **jede** Eigenschaft aus §10 ist auf den konkreten durchsetzenden Mechanismus und den beweisenden Canary abgebildet. Eine Eigenschaft mit „angenommen" ist ein No-Go.
6. Die Canary-Liste enthält zusätzlich: Ergebnisdatei aus der Nutzlast fälschen · Envelope-Größe überschreiten · Bundle-Mount manipulieren · einen zweiten Ausgabekanal öffnen. Jeder Canary hat ein **technisches** Fehlersignal, kein beobachtendes.
7. Die API-Schlüssel sind entweder rotiert, **oder die Risikoannahme aus §13 ist für die Bauphase neu und schriftlich bestätigt** — die S1-Canaries werden absichtlich versuchen, Geheimnisse zu lesen.
8. Es existiert kein Code, der nicht vertrauenswürdige Bytes auf dem Host über Hash, Größe, Speichern und Weiterreichen hinaus interpretiert.

Fällt eines davon durch: **No-Go, erst das Dokument reparieren.** Prosa zu korrigieren ist billiger als einen laufenden Käfig.

---

## 12. Reihenfolge

| | Inhalt |
|---|---|
| **S0** | dieses Dokument, geprüft, Go/No-Go erfüllt |
| **S1** | gehärtete wegwerfbare VM, Escape- und Quota-Canaries — **als dauerhafte Regressionsprüfung**, nicht als einmaliges Tor |
| **S2** | netzloser Baulauf plus Host-Broker |
| **S3** | unveränderliches Acceptance Bundle, Prüflauf mit Supervisor/Nutzlast-Split |
| **S4** | Ende zu Ende mit absichtlich bösartigem Fake, der jeden Canary in einem Lauf versucht |
| **S5** | echtes Modell und Dispatcher |

**Kein echtes Modell vor bestandener S1–S4-Abnahme.**

**LATER, außerhalb des Execution Core:** Zweitmodell- oder Mensch-Review von Work Orders (die `wo-98-3`-Klasse) · reproduzierbare Image-Builds; vorerst genügt ein gepinnter Digest eines von Hand gebauten Images.

---

## 13. Vom Owner angenommenes Risiko

Der Owner hat die Rotation der API-Schlüssel **ausdrücklich abgelehnt** (2026-07-27).

- `~/.config/secrets/env` (chmod 600) war für builder-geschriebenen Code lesbar, der dreimal mit Owner-Rechten ausgeführt wurde.
- Ob gelesen wurde, ist **unbekannt und nicht feststellbar** — die Ausgabe wurde nach `/dev/null` verworfen.
- Host-Prüfung ohne Auffälligkeiten: keine neuen LaunchAgents, kein crontab, `~/.ssh` unberührt, Shell-Konfiguration seit dem 26.7. unverändert.
- Netzverkehr wurde nicht aufgezeichnet und ist nicht rekonstruierbar.

**Nicht widerlegt, sondern angenommen.** Datiert und zurechenbar.

**Offen für S1:** Die Canaries werden absichtlich versuchen, diese Datei zu lesen. Die Annahme gilt für die Vergangenheit; für die Bauphase braucht es eine neue Entscheidung (§11.7).

---

## 14. Was gestrichen wurde

Gegenüber Revision 2 entfernt, weil Zeremonie oder falsch benannt:

- **gVisor** als Kandidat — falsche Schicht, importiert stille Fehler
- **Die A/B-Asymmetrie** — ein Image, ein Launcher-Pfad, zwei Läufe mit anderen Eingaben
- **`allowed_paths` in jeder Form**, auch als Lint
- **Neustarts** als Konzept
- **Werkzeugdiskussion in §10** über „Kandidat, per Canary zu prüfen" hinaus
- **„Quarantäne"** der `operator/run.sh`-Maschinerie — es ist Löschung, nicht Quarantäne

## 15. Was bewusst fehlt

**Ein Zeitplan.** Jede Schicht hat beim ersten echten Kontakt einen Defekt offenbart. Ein Datum wäre eine Behauptung über Arbeit, die niemand gesehen hat.
