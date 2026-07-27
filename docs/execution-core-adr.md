# ADR — Execution Core S0: Bedrohungsmodell, Vertrauensgrenzen, Ausführungsprotokoll

**Status:** Entwurf, Revision 4. Kein Code, bis die Go/No-Go-Kriterien in §11 erfüllt sind.
**Anlass:** #104 — `acceptance_commands` waren beliebige Codeausführung mit den Rechten des Owners. Dreimal real gelaufen.
**Revision 4:** Substrat entschieden, gemessen statt vermutet. Kein Docker, keine VM, keine externen Abhängigkeiten — reines Python plus macOS-Seatbelt. Neu: §0 (der eigentliche Fix), §10 (Substrat mit Messwerten), §16 (Kosten und Zeit). Vorherige Revision:

**Revision 3:** Nach REQUEST CHANGES. Die TCB war falsch durch Auslassung, der Verifier konnte sein eigenes Urteil fälschen, der Launcher glaubte Selbstauskünfte, und der Work Order durfte seine eigenen Grenzen setzen. Sechs Bestandteile wurden als Zeremonie gestrichen (§14) — das Dokument ist deshalb trotzdem nicht kürzer (247 gegen 236 Zeilen), weil die vollständige TCB, die Messliste und die Go/No-Go-Kriterien mehr Platz brauchen als das Gestrichene. Ich hatte „kürzer" behauptet, ohne zu zählen.

---

## 0. Der eigentliche Fix, vor allem anderen

> **Der Supervisor führt niemals Builder-Ausgabe im eigenen Prozess aus.**

Kein `eval`, kein `source`, kein Aufruf einer Datei, die der Builder geschrieben hat. Ergebnisse kommen **ausschließlich als Dateien** zurück, die der Supervisor **liest und parst** — nie ausführt.

Das behebt #104 vollständig und kostet nichts. Sandkasten, Benutzertrennung und Grenzen sind **Schicht zwei**: sie fangen ab, was passiert, wenn diese Regel irgendwann durch einen Bequemlichkeitspfad gebrochen wird.

Diese Reihenfolge steht hier, weil die drei vorherigen Revisionen mit dem Sandkasten anfingen und den Satz oben nicht enthielten.

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

## 10. Substrat — entschieden, gemessen

**Kein Docker, keine VM, keine externen Abhängigkeiten.** Reines Python (Standardbibliothek) plus macOS-Seatbelt.

### Gemessen auf dieser Maschine

| Prüfung | Ergebnis |
|---|---|
| `sandbox-exec`, Netz | gesperrt |
| `sandbox-exec`, Schreiben außerhalb | `Operation not permitted` |
| `sandbox-exec`, Secrets lesen — Profil mit `(allow file-read*)` | **gelungen — Allow-by-default ist Theater** |
| `sandbox-exec`, Secrets und `$HOME` — Deny-by-default-Profil | gesperrt |
| Deny-by-default-Profil, legitime Arbeit | **ebenfalls gesperrt** — Systempfade fehlten |
| `RLIMIT_CPU` | greift, Prozess getötet |
| `RLIMIT_AS` (Speicher) | **`ValueError` — auf macOS nicht setzbar** |

### Aufbau

```
sudo -u builder env -i sandbox-exec -f profile.sb /usr/bin/python3 job.py
```

- **Eine** NOPASSWD-sudoers-Zeile, sonst nichts.
- `env -i` — die Umgebung des Owners überquert die Grenze nie.
- Eigener unprivilegierter Benutzer: DAC greift auch dann noch, wenn das Profil leckt. Genau das ist heute passiert.
- `preexec` setzt `RLIMIT_CPU`, `RLIMIT_NPROC`, `RLIMIT_FSIZE` — alle drei nachweislich wirksam.

### Speicher: erkennen, nicht verhindern

Es gibt auf macOS **keine verlässliche, öffentlich unterstützte Speichergrenze pro Prozess** ohne VM. `RLIMIT_AS` ist kaputt, gemessen. Die echten Mechanismen sind private APIs.

Stattdessen: Watchdog im Elternprozess, RSS jede Sekunde pollen, bei Schwellwert töten. Das Zeitfenster einer Abfrage bleibt offen; die Folge ist Swap-Druck, kein Datenverlust. **Als Einschränkung benannt, nicht als Lösung verkauft.**

### Das Profil und seine Fäulnis

40–60 Zeilen SBPL, Deny-by-default, Lese- und Ausführrechte auf SIP-geschützte Systempfade (`/usr`, `/bin`, `/System`, dyld-Cache, `/dev/null`, `/dev/urandom`), Schreiben nur im Arbeitsverzeichnis, `network*` verboten.

**Der Fäulnisvektor ist Druck, nicht Größe.** Ein Auftrag scheitert, jemand fügt nachts ein breites `allow` ein, um zu entsperren, und es kommt nie wieder heraus. Exakt so ist das undichte Profil in der Messung oben entstanden.

Disziplin, ohne die es still verrottet:

1. Profil in Versionskontrolle.
2. Die vier Handproben werden eine **dauerhafte Canary-Suite**: Netz muss scheitern, ein platziertes Fake-Secret muss unlesbar sein, Schreiben außerhalb muss scheitern, Arbeit innerhalb muss gelingen. Lauf bei **jedem** Supervisor-Start, fail-closed.
3. **Keine `allow`-Zeile ohne gepaarten Negativtest**, der zeigt, was sie weiterhin verbietet.
4. Fehlende Rechte aus dem tatsächlichen Sandbox-Verstoß im Unified Log ableiten (`log show --predicate 'subsystem == "com.apple.sandbox"'`), niemals breit raten.

### Was schlecht altert

- `sandbox-exec` ist deprecated und SBPL undokumentiert. Ein OS-Update kann das Profil laut brechen (ärgerlich, sicher) oder Semantik ändern, sodass ein `allow` breiter wird als gemeint (still, gefährlich). **Nur die Canaries merken das.**
- Profil-Aufweichung unter Lieferdruck, eine Zeile nach der anderen.
- Der Supervisor wächst sich einen Bequemlichkeitspfad, der Builder-Ausgabe im Prozess ausführt — und baut §0 leise wieder ab.

### Was das nicht ist

Keine Grenze gegen einen Kernel-Exploit. Speicher ist Erkennung, nicht Verhinderung. **Für eine Maschine und einen Owner ist das eine vertretbare und ehrliche Position — vorausgesetzt, die Canaries laufen für immer.**

### Offene Entwurfsfrage

Ein sandgekasteter Prozess hat kein Netz. Der Builder **ist** aber ein Modellaufruf. Zwei mögliche Formen, und diese Entscheidung ist **nicht getroffen**:

- **(a)** Der Modell-Client läuft im Sandkasten, das Credential bleibt draußen, ein host-seitiger Proxy vermittelt. Der Broker aus §9 bleibt.
- **(b)** Der Supervisor ruft das Modell selbst auf, empfängt den Vorschlag als **Daten**, und der Sandkasten dient nur dem **Ausführen und Prüfen**. Der Broker entfällt als Komponente.

**(b)** ist kleiner und passt zu §0 — der Supervisor behandelt Modellausgabe als Daten. **(a)** ist nötig, sobald der Bau selbst Netz braucht (`pip install`, `npm install`). Fable hat unabhängig davon vorhergesagt, dass die Kein-Netz-Regel genau daran zuerst bricht.

Das ist die eine Frage, die vor S1 entschieden werden muss.

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

**Erledigt am 2026-07-27:** `~/.config` und `~/.config/secrets` waren `755` — nur die Datei selbst `600`. Ein separater `builder`-Benutzer hätte das Verzeichnis betreten und auflisten können. Jetzt `700`. Rückgängig mit `chmod 755 ~/.config/secrets`.

**Offen für S1:** Die Canaries werden absichtlich versuchen, diese Datei zu lesen. Die Annahme gilt für die Vergangenheit; für die Bauphase braucht es eine neue Entscheidung (§11.7).

---

---

## 16. Kosten und Zeit

Bis Revision 3 hat niemand das geprüft. Der Betrieb am 2026-07-27 lief Stunden für vier Aufgaben.

### Wohin es tatsächlich geht

**Geld:** in **Wiederholungen mit wachsendem Kontext.** Jeder Fehlversuch sendet das größer gewordene Transcript erneut, die Kosten steigen also überlinear mit der Versuchszahl — und ein Frontier-Modell in der inneren Schleife multipliziert das.

**Zeit:** in **Gates × Versuche.** Sechs Minuten pro vollem Gate sind einmal in Ordnung und ruinös, wenn jede Iteration sie bezahlt. Stundenlange Läufe sind fast immer Versuche mal Gate, nicht Nachdenken.

Beleg aus dem Betrieb: elf Dispatches, jeder mit gewachsenem Kontext, mehrere volle Gate-Läufe je Aufgabe.

### Routing-Leiter

| Stufe | Wofür | Regel |
|---|---|---|
| **Flash** | erster Versuch jedes gut spezifizierten Auftrags, mechanische Änderungen, Zusammenfassungen | **Kontext pro Versuch zurücksetzen**, nicht anhäufen |
| **Pro** | Eskalation nach zwei Flash-Fehlschlägen; Fehlersuche mit echter Fehlerausgabe in der Hand | |
| **Frontier-Operator** | Aufträge schreiben und zerlegen; alles prüfen, was Sandkasten-Profil, sudoers-Zeile oder Supervisor berührt | **niemals in der inneren Schleife** |
| **niemals Modellarbeit** | Verifikation (Tests und Canaries sind deterministische Skripte) · die Routing-Entscheidung selbst · Umgang mit Geheimnissen · alles, was der vertraute Prozess ausführt | |

### Vor-Gate und Versuchsgrenzen

- **Schnelles Vor-Gate** bei jeder Iteration: Sekunden, nicht Minuten — Syntax, gezielte Tests, Canaries.
- **Volles Gate** nur auf dem Kandidaten für die Abgabe.
- **Drei Versuche pro Stufe**, dann eskalieren, dann anhalten und vorlegen. Unbegrenzte Schleifen sind der Ort, an dem beide Budgets sterben.

---

## 14. Was gestrichen wurde

Gegenüber Revision 2 entfernt, weil Zeremonie oder falsch benannt:

- **gVisor** als Kandidat — falsche Schicht, importiert stille Fehler
- **Die A/B-Asymmetrie** — ein Image, ein Launcher-Pfad, zwei Läufe mit anderen Eingaben
- **`allowed_paths` in jeder Form**, auch als Lint
- **Neustarts** als Konzept
- **Werkzeugdiskussion in §10** über „Kandidat, per Canary zu prüfen" hinaus
- **„Quarantäne"** der `operator/run.sh`-Maschinerie — es ist Löschung, nicht Quarantäne

Zusätzlich in Revision 4 gestrichen:

- **VM- und Container-Maschinerie** — Docker ist auf dieser Maschine ausgeschlossen, und eine selbstverwaltete VM war die überbaute Antwort auf eine gemessene Bedrohung
- **Der Broker als eigene Komponente** — vorbehaltlich der offenen Frage in §10; bei Form (b) entfällt er
- **Der Supervisor/Nutzlast-Split als VM-internes Konstrukt** — er wird durch zwei getrennte sandgekastete Aufrufe erreicht, deren Ergebnisse der Supervisor von außen liest

## 15. Was bewusst fehlt

**Ein Zeitplan.** Jede Schicht hat beim ersten echten Kontakt einen Defekt offenbart. Ein Datum wäre eine Behauptung über Arbeit, die niemand gesehen hat.
