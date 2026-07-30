# ADR — Execution Core: Bedrohungsmodell, Vertrauensgrenzen, Ausführungsprotokoll

**Status:** Proposed. Kein bewiesenes Sicherheitsfundament — ein Vertrag, dessen Backends ihre Fähigkeiten erst durch Canaries nachweisen müssen (§7, §11).
**Anlass:** #104 — `acceptance_commands` waren beliebige Codeausführung mit den Rechten des Owners. Dreimal real gelaufen.
**Revision 6.** Sechs Abschlussänderungen, kein neuer Entwurf. Revision 5 war die vollständige Neufassung. Revision 4 entschied in einem Abschnitt „keine VM" und ließ TCB, Diagramm, Messmodell und Roadmap weiter von Hypervisor und VM-Zerstörung sprechen. Diese Fassung ist in sich konsistent oder sie ist wertlos.

---

## 0. Der eigentliche Fix, vor allem anderen

> **Der Supervisor führt niemals Worker-Ausgabe im eigenen Prozess aus.**

Kein `eval`, kein `source`, kein Aufruf einer Datei, die der Worker geschrieben hat. Ergebnisse kommen als Dateien zurück und werden **gelesen und geparst** (§5), nie ausgeführt.

Das behebt #104 vollständig und kostet nichts.

**Es ersetzt keine Isolation.** Es verhindert nur, dass Worker-Ausgabe unmittelbar zu Codeausführung auf dem Host wird. Alles Weitere in diesem Dokument existiert für den Fall, dass diese Regel bricht.

---

## 1. Was tatsächlich passiert ist

Drei echte Läufe am 2026-07-27, DeepSeek über `jcode`, auf dem Rechner des Owners, als der Owner, ohne Isolation.

| Lauf | Verdikt | Was er zeigte |
|---|---|---|
| `wo-98-1` | accepted | Die Ausführungsebene verwarf die geprüfte Arbeit (#99) |
| `wo-98-2` | rejected | Werkzeug schrieb außerhalb der erlaubten Pfade; Builder meldete `completed` (#101) |
| `wo-98-3` | accepted | Arbeit war inhaltlich falsch und schädlich; Abnahme war zirkulär (#103) |

Wörtlich in `operator/run.sh`:

```bash
(cd "$WORKTREE" && eval "$cmd") >/dev/null 2>&1
```

Ein Abnahmekommando durfte auf eine Datei zeigen, die der Builder erzeugt hat. `git cat-file -e <base_sha>:scripts/test/gate-cleanup.bats` → existierte nicht. **Der Builder schrieb die Datei, der Orchestrator führte sie mit Owner-Rechten aus, mit unterdrückter Ausgabe.**

---

## 2. Der Agentenfluss — entschieden

**Das Modell läuft außerhalb der Isolationsgrenze. Seine Antworten sind Daten.**

```
Supervisor (Host)              Worker (isoliert)
─────────────────              ─────────────────
ruft das Modell auf
hält das Credential
empfängt Antwort als DATEN
        │
        │ schreibt Auftrag + Daten in den Arbeitsraum
        ▼
                               führt Werkzeuge aus
                               führt Code aus
                               schreibt Ergebnisdateien
        ◄──────────────────────
liest und parst (§5)
führt niemals aus (§0)
```

**Jeder Werkzeugaufruf und jede Codeausführung findet ausschließlich im isolierten Worker statt.** Der Modell-Client läuft auf dem Host und gehört damit zur TCB.

**Iterationspfad, ausdrücklich:** Größenbegrenzte Worker-Ausgabe darf dem Modell als **untrusted Daten** zurückgegeben werden — niemals ausgeführt. Jeder weitere Werkzeugaufruf ist ein **neuer isolierter Worker-Lauf**. Keine Host-Dateien und keine Geheimnisse gelangen in diesen Kontext.

Folgen dieser Entscheidung:

- **Der Broker entfällt als Komponente.** Es gibt keinen Modellaufruf aus dem Worker heraus, den man vermitteln müsste.
- Der Worker braucht für den Bau selbst **kein Netz**.
- **Paketinstallation ist damit nicht gelöst, sondern ausgeschlossen.** Ein Auftrag, der `pip install` oder `npm install` braucht, ist auf einem Backend ohne Netz-Fähigkeit **nicht ausführbar** und wird abgelehnt (§7). Das ist eine benannte Grenze, keine spätere Ausnahme.

---

## 3. Vertrauen

### 3.1 Trusted Computing Base

> Eine TCB, die man zu klein angibt, ist eine TCB, die man nicht prüft.

1. **Der Owner**
2. **Der Supervisor** — klein, deterministisch, kein Modell, klein genug zum Ganzlesen
3. **Das Host-Betriebssystem**
4. **Die Implementierung des Isolation-Backends** samt Profil oder Policy (§7)
5. **Der Modell-Client auf dem Host** — er hält das Credential (§2)
6. **Die Canary-Suite** — sie entscheidet, welche Fähigkeiten ein Backend behaupten darf
7. **Die Supervisor-Policy** — sie legt die Grenzen fest

Kein Hypervisor in dieser Liste: ob einer existiert, hängt vom gewählten Backend ab (§7). Ein VM-Backend fügt ihn hinzu, ein Prozess-Backend nicht.

### 3.2 Nicht vertrauenswürdig

Der LLM-Operator · das Builder-Modell und seine Ausgabe · das Repository einschließlich `base_sha` · die Tests im Repository · der Patch · **alles, was im Worker läuft** · jede Ausgabe eines Laufs.

### 3.3 Was daraus folgt

Der Operator darf Aufträge **vorschlagen** und Ergebnisse **lesen**. Er führt nicht aus, sperrt nicht ein, gibt nicht frei.

**Unbequeme Folge:** Was der Operator „Abnahme" nennt, sind **Behauptungen, keine Feststellungen**. Evidenz entsteht dort, wo der Supervisor unabhängig misst (§6).

### 3.4 Dieses Dokument ist untrusted output

Vom Operator geschrieben, nach §3.2 also nicht vertrauenswürdig. Es braucht Prüfung durch jemand anderen.

### 3.5 Was diese Architektur NICHT schützt

1. **Ein falscher Auftrag.** `wo-98-3` bestand jede mechanische Prüfung und war schädlich. Kein Backend behebt das.
2. **Semantische Korrektheit.** Bleibt menschliche Lektüre.
3. **Eine gebrochene TCB.**
4. **Den Modellanbieter.** Er sieht, was der Supervisor sendet.

---

## 4. Ablauf

Zwei getrennte isolierte Läufe, ein Supervisor.

```
TCB: Owner · Supervisor · Host-OS · Backend+Policy · Modell-Client · Canaries
   │
   │ 1. Modellaufruf auf dem Host → Antwort als Daten
   │ 2. Arbeitsraum anlegen, Base + Auftrag hineinschreiben
   ▼
┌─ Lauf 1: BAU, isoliert ──────┐
│  kein Netz                    │
│  Ausgang: Ergebnisdateien     │
└───────────────────────────────┘
   │ 3. Supervisor liest, parst (§5), misst (§6)
   ▼
┌─ Lauf 2: PRÜFUNG, frisch ────┐
│  Base + Patch + Acceptance    │
│  Bundle (nie in Lauf 1)       │
│  kein Netz                    │
└───────────────────────────────┘
   │ 4. Supervisor liest Exitstatus des Kindes selbst
   ▼
   Verdikt
```

**Zwei getrennte Läufe ersetzen den früher geforderten Supervisor/Nutzlast-Split innerhalb einer VM.** Das Acceptance Bundle betritt Lauf 1 nie; der geprüfte Code kann sein eigenes Urteil nicht schreiben, weil der Supervisor das Urteil **von außen** aus dem Exitstatus des Kindprozesses bildet.

---

## 5. Was der Supervisor parsen darf

„Der Host interpretiert nichts" war unmöglich und widersprach §0 — ein Ergebnis muss gelesen werden, sonst gibt es kein Verdikt.

**Erlaubt, und nur das:**

- Bytegrößen-Prüfung **vor** jedem Lesen
- **Kanonisches JSON**, strikt gegen ein festes Schema, Tiefe und Feldzahl begrenzt
- Der Patch als **opake Bytes**: Größe, Hash, Weiterreichen

**Verboten, ohne Ausnahme:** Ausführen · `pickle` · YAML · Archive entpacken · beliebige Deserialisierung · jedes Format, dessen Parser Code ausführen kann.

Das Anwenden und Untersuchen des Patches geschieht im Prüflauf, nicht auf dem Host.

---

## 6. Was der Supervisor unabhängig misst

Nichts Verdikt-Relevantes stammt aus dem Worker.

| Messgröße | Quelle |
|---|---|
| Exitstatus und Terminierungssignal | `waitpid` des Elternprozesses |
| Wanduhr Start/Ende | Supervisor |
| Verbrauchte CPU-Zeit | `rusage` des Kindes |
| Spitzen-RSS | Watchdog des Supervisors |
| Patch-Hash und Bytegröße | Supervisor |
| Ergebnis-Bytegröße | Supervisor |
| Digest des Acceptance Bundles | Supervisor |
| Backend-Identität und Profil-Digest | Supervisor |
| `run_id`-Bindung über alle Artefakte | Supervisor |
| Tatsächliche Anwendung jeder Grenze | Supervisor |

**Fehlende Evidenz ist Ablehnung.** „Nicht gemessen" und „eingehalten" dürfen nie dasselbe Ergebnis haben.

---

## 7. Der Isolation-Backend-Vertrag

**Das ist der Kern dieses ADR.** Der Execution Core kennt kein Betriebssystem und keine Sandkasten-Technik. Er kennt **Fähigkeiten**, die ein Backend behauptet und deren Nachweis er verlangt.

### 7.1 Fähigkeiten

| Fähigkeit | Bedeutung |
|---|---|
| `no_network` | Kein Netzzugriff, kein DNS aus dem Worker |
| `fs_confinement` | Lesen und Schreiben nur im Arbeitsraum; kein Zugriff auf `$HOME`, Secrets, fremde Pfade |
| `cpu_limit` | Durchgesetzte CPU-Obergrenze **für den gesamten Prozessbaum** |
| `mem_limit` | Durchgesetzte Speichergrenze — **Verhinderung, nicht Erkennung** |
| `pid_limit` | Durchgesetzte Prozessobergrenze |
| `disk_quota` | Durchgesetzte Obergrenze für **die Summe** erzeugter Daten |
| `tree_kill` | Zuverlässiges Töten des gesamten Prozessbaums — **auch eines Kindes, das per `setsid`, Double-Fork und Daemonisierung die ursprüngliche Prozessgruppe verlassen hat.** `kill(-pgid)` allein genügt nicht. Der Canary muss einen echten Ausbruchsversuch enthalten; erst wenn auch dieser Baum vollständig stirbt, darf ein Backend `tree_kill` behaupten |
| `package_network` | Netz ausschließlich zu einem Paket-Spiegel mit Allowlist |

### 7.2 Die Regel

> **Ein Backend darf nur die Fähigkeiten behaupten, die seine Canaries beweisen.**
> **Ein Auftrag, der eine nicht bewiesene Fähigkeit braucht, wird abgelehnt — nicht ausgeführt.**

Die Ablehnungsmeldung nennt **die fehlende Fähigkeit, das Backend und die exakte Policy-Regel**, die ablehnt. Damit führt der legitime Änderungsweg über eine sichtbare Policy-Änderung statt über das Abschalten von Canaries.

**Es gibt kein `--skip-canaries`**, keinen stillen Fallback und kein zwischengespeichertes Ergebnis von gestern.

Jede Fähigkeit hat genau einen Canary mit **technischem** Fehlersignal. Die Canary-Suite läuft bei jedem Supervisor-Start und ist fail-closed: kippt ein Canary, verliert das Backend die Fähigkeit sofort, und Aufträge, die sie brauchen, werden abgelehnt.

### 7.3 Backend `macos-seatbelt` — Prototyp, bekannte Grenzen

Aufbau: `sudo -u worker env -i sandbox-exec -f profile.sb /usr/bin/python3 job.py`, eine NOPASSWD-sudoers-Zeile, eigener unprivilegierter Benutzer, `env -i`, `rlimits` im `preexec`, RSS-Watchdog im Supervisor.

**Auf dieser Maschine gemessen:**

| Prüfung | Ergebnis |
|---|---|
| Netz aus dem Sandkasten | gesperrt |
| Schreiben außerhalb | `Operation not permitted` |
| Secrets lesen, Profil mit `(allow file-read*)` | **gelungen — Allow-by-default ist Theater** |
| Secrets und `$HOME`, Deny-by-default-Profil | gesperrt |
| Deny-by-default-Profil, legitime Arbeit | **ebenfalls gesperrt** — Systempfade fehlten |
| `RLIMIT_CPU` | greift, Prozess getötet |
| `RLIMIT_AS` (Speicher) | **`ValueError` — auf macOS nicht setzbar** |

**Behauptbare Fähigkeiten:** `no_network`, `fs_confinement`, `pid_limit`,
`tree_kill`, `kill_persistent`, `symlink_egress`, `ingress_symlink`,
`pool_integrity` — jeweils nach bestandenem Canary.

Seit S1 ist jede Fähigkeit ein **Paar** aus Verweigerung und Erhaltung, nicht
eine Verweigerungseigenschaft allein. Ein Loch besteht jeden Erhaltungstest,
eine Leiche besteht jeden Verweigerungstest — dieses Projekt hat eine Leiche
ausgeliefert: eine Härtung legte Eingabedateien als `0600` an, der Worker konnte
seine eigene Konfiguration nicht mehr lesen, die Sandbox war funktionsunfähig,
und alle sieben Canaries blieben grün. Dieselbe Änderung als Mutation gegen den
heutigen Stand macht zwei Canaries rot und verweigert die Bereitschaftsmeldung.

**Gemessene Grenze bei `tree_kill`.** Der Canary belegt die Fähigkeit: der Slot
erreicht null Prozesse und bleibt dort, gegen einen Baum, der nachweislich
regeneriert (gemessen: 11 von 14 PIDs binnen 0,3 s ausgetauscht). Was **nicht**
gemessen ist, ist die Notwendigkeit des STOP-dann-KILL-Protokolls: ein einzelnes
`pkill -9` räumt denselben Baum ebenso vollständig ab, und zwei direkte
Experimente zur Unterscheidung sind an der Instrumentierung gescheitert, nicht
an der Sache. Das Protokoll bleibt, weil es strikt stärker ist und nichts
kostet, und weil das Argument dafür — `pkill` durchläuft die Prozesstabelle
nicht atomar, ein früh besuchter Prozess kann einen Ersatz forken, der nie
besucht wird — theoretisch tragfähig ist. Es bleibt **begründet, nicht belegt**.
Wer es später entfernt, entfernt eine Annahme, keinen Messwert.

**Nicht behauptbar:**

- **`mem_limit`** — `RLIMIT_AS` ist auf macOS nicht setzbar; der Watchdog **erkennt**, er verhindert nicht. Erkennung ist keine Grenze.
- **`disk_quota`** — `RLIMIT_FSIZE` begrenzt eine **einzelne Datei**, nicht die Summe. Zehntausend Dateien unter dem Limit füllen die Platte.
- **`cpu_limit`** — `RLIMIT_CPU` gilt **pro Prozess**, nicht für den Baum. Ein Prozessbaum umgeht das Budget durch Aufteilen.
- **`package_network`** — nicht gebaut.

**Folge:** Auf diesem Backend sind Aufträge, die verlässliche Speicher-, Platten- oder Baum-CPU-Grenzen brauchen, **nicht ausführbar**. Das ist keine Schwäche der Dokumentation, sondern ihre Aufgabe.

**Fäulnis:** `sandbox-exec` ist deprecated und SBPL undokumentiert. Ein OS-Update bricht das Profil entweder laut (sicher) oder verschiebt Semantik still (gefährlich). Der Fäulnisvektor ist **Druck, nicht Größe**: ein breites `allow`, nachts eingefügt, um zu entsperren — exakt so entstand das undichte Profil in der Messung oben. **Keine `allow`-Zeile ohne gepaarten Negativtest.** Fehlende Rechte aus dem Sandbox-Log ableiten, nie breit raten.

### 7.4 Backend `linux-namespaces` — später, stärker

cgroups v2 liefern durchgesetzte Speicher-, PID-, CPU- und IO-Grenzen für den gesamten Baum; Netz-Namespaces liefern echtes `no_network`. Ein solches Backend kann alle Fähigkeiten aus §7.1 behaupten, **wenn seine Canaries sie beweisen.**

**Der Execution Core ändert sich dafür nicht.** Das ist der Zweck des Vertrags.

---

## 8. Grenzen

Aus der **Supervisor-Policy**, nicht aus dem Auftrag. Ein Auftrag darf **engere** Grenzen erbitten, niemals lockerere.

CPU · Speicher · PIDs · Disk · Laufzeit · Patchgröße · Ergebnisgröße · Modellaufrufe.

Jede Grenze ist an eine Fähigkeit aus §7.1 gebunden. **Eine Grenze ohne bewiesene Fähigkeit ist keine Grenze** — der Supervisor lehnt den Auftrag ab, statt ihn ungeschützt auszuführen.

Überschreitung oder fehlende Evidenz: **reject, Arbeitsraum zerstören.**

**Ein Lauf wird niemals fortgesetzt oder wiederaufgenommen.** Ein erneuter Versuch ist ein vollständig neuer Lauf: neue `run_id`, neuer Arbeitsraum, frischer Modellkontext. Nichts aus einem abgelehnten Lauf wird übernommen.

---

## 9. Ergebnisformat

Genau eine begrenzte Struktur verlässt den Bau-Lauf: `patch` (opake Bytes) · `exit_status` · `stdout`/`stderr` (untrusted, größenbegrenzt, markiert abgeschnitten) · `run_id`.

Digests und Messwerte stehen **nicht** darin — der Supervisor misst sie selbst (§6). Alles außerhalb der Struktur wird verworfen.

---

## 10. Acceptance Bundle

Vorbestehende Repo-Tests sind **keine vertrauenswürdigen Orakel.** Ein Patch kann eine Testdatei unberührt lassen und sie über einen Helper, Konfiguration, eine Abhängigkeit oder Fixtures neutralisieren.

Das Bundle ist ein eigenes, unveränderliches Artefakt **außerhalb des Patch-Baums**, selbstgenügsam, **betritt den Bau-Lauf nie**, wird im Prüflauf schreibgeschützt bereitgestellt. Repo-Tests dürfen ergänzend laufen, nie allein entscheiden.

**Provenienz, verbindlich:**

- **vor** dem Bau-Lauf erstellt
- außerhalb des Patch-Baums
- Digest **vor** dem Lauf gebunden
- **niemals vom geprüften Builder erzeugt oder verändert**
- Autor und Freigabe im Run Record dokumentiert

Schreibt der Operator das Bundle selbst, erbt die Abnahme nach §3.3 den Status **Behauptung, nicht Feststellung** — bis das Zweit-Review aus §12 LATER existiert. Das ist die `wo-98-3`-Klasse und muss hier stehen, nicht implizit bleiben.

---

## 11. Go/No-Go vor S1

Jedes Kriterium ist durch **Lesen** prüfbar.

1. §3.1 vollständig, geprüft von jemand anderem als dem Operator, datierte Freigabe des Owners.
2. Das Auftragsschema kann gelockerte Grenzen **strukturell nicht ausdrücken**; eine Datei bösartiger Testvektoren, die der Validator zurückweisen muss. Validator rein, deterministisch, ohne Shell-Aufruf.
3. Die Messliste aus §6 liegt als feste Checkliste vor, „fehlend = reject" pro Punkt.
4. **Der Fähigkeitsvertrag aus §7.1 ist festgeschrieben, und für jede Fähigkeit existiert genau ein Canary mit technischem Fehlersignal.**
5. **Das gewählte Backend behauptet keine Fähigkeit, deren Canary nicht besteht.** Eine Fähigkeit mit „angenommen" ist ein No-Go.
6. Der Supervisor **lehnt nachweislich ab**, wenn ein Auftrag eine nicht bewiesene Fähigkeit braucht — mit Testvektor.
7. Die Parsing-Regel aus §5 ist implementiert: Bytelimit vor Lesen, kanonisches JSON gegen festes Schema, kein `pickle`, kein YAML, keine Archive.
8. Die API-Schlüssel sind entweder rotiert **oder die Risikoannahme aus §13 ist für die Bauphase neu und schriftlich bestätigt** — die S1-Canaries versuchen absichtlich, Geheimnisse zu lesen.

Fällt eines durch: **No-Go, erst das Dokument reparieren.**

---

## 12. Reihenfolge

| | Inhalt |
|---|---|
| **S0** | dieses Dokument als *Proposed* — ein Vertrag, keine bewiesene Sicherheitsarchitektur |
| **S1** | Spike: Backend `macos-seatbelt` plus vollständige Canary-Suite, **mit absichtlich bösartigem Fake-Angreifer**, kein echtes Modell |
| **S2** | Supervisor: Auftragsvalidierung, Fähigkeitsprüfung, Ablehnung nicht abgedeckter Aufträge, Messung nach §6 |
| **S3** | Prüflauf mit unveränderlichem Acceptance Bundle |
| **S4** | Ende zu Ende mit bösartigem Fake, der jeden Canary in einem Lauf versucht |
| **S5** | echtes Modell |

**Kein echtes Modell vor bestandener S1–S4-Abnahme.**

**LATER:** Backend `linux-namespaces` · `package_network` · Zweitmodell- oder Mensch-Review von Aufträgen (die `wo-98-3`-Klasse).

---

## 13. Vom Owner angenommenes Risiko

Rotation der API-Schlüssel **ausdrücklich abgelehnt** (2026-07-27).

- `~/.config/secrets/env` war für Code lesbar, der dreimal mit Owner-Rechten ausgeführt wurde.
- Ob gelesen wurde, ist **nicht mehr feststellbar** — die Ausgabe wurde verworfen.
- Host-Prüfung ohne Auffälligkeiten: keine neuen LaunchAgents, kein crontab, `~/.ssh` unberührt.
- Netzverkehr nicht aufgezeichnet, nicht rekonstruierbar.

**Erledigt 2026-07-27:** `~/.config` und `~/.config/secrets` waren `755`, nur die Datei `600`. Jetzt `700`. Rückgängig mit `chmod 755 ~/.config/secrets`.

**Nicht widerlegt, sondern angenommen.** Offen für S1: die Canaries werden absichtlich versuchen, diese Datei zu lesen (§11.8).

---

## 14. Was Revision 4 falsch hatte

- **VM und Seatbelt gleichzeitig.** §10 entschied „keine VM", TCB, Diagramm, Messmodell und Roadmap sprachen weiter von Hypervisor und VM-Zerstörung. Ein Abschnitt wurde gepatcht statt des Dokuments.
- **Seatbelt als entschiedenes Fundament**, obwohl es drei der geforderten harten Grenzen nachweislich nicht liefert. Jetzt ein **Backend mit benannten Grenzen** unter einem portablen Vertrag.
- **„Der Host interpretiert nichts"** — unmöglich und im Widerspruch zu §0. Ersetzt durch eine positive Regel (§5).
- **Der Agentenfluss blieb offen.** Jetzt entschieden (§2): Modell außerhalb, Antworten sind Daten, Broker entfällt.
- **`allowed_paths`** in jeder Form gestrichen — unter zwei Namen zweimal gescheitert.

## 15. Was bewusst fehlt

**Ein Zeitplan.** Jede Schicht hat beim ersten echten Kontakt einen Defekt offenbart.

**Kosten- und Routingregeln.** Sie standen in Revision 5 als §15 hier und gehören nicht in eine Sicherheitsgrenze. Sie ziehen in ein eigenes Operations-Dokument um, dort ergänzt um: maximales Tokenbudget pro Auftrag, maximales Kostenbudget pro Auftrag, maximale Versuche, harter Stop bei Überschreitung.

**Ein Sicherheitsversprechen.** Dieses Dokument ist ein *Proposed ADR*: ein Vertrag darüber, welche Fähigkeiten nachgewiesen werden müssen. Bewiesen ist nach S1 genau das, was die Canaries zeigen — und nicht mehr.
