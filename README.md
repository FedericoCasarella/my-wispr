# My Wispr

App nativa macOS per dettare nei campi di testo, recuperare gli appunti e raccogliere note vocali.

## Installazione

Scarica il DMG dalla [pagina delle release](https://github.com/FedericoCasarella/my-wispr/releases), aprilo e trascina **MyWispr.app** in **Applications**. Apri l’app dalla cartella Applicazioni.

Richiede **Mac Apple Silicon e macOS 26 o successivo**. La release iniziale è un’anteprima con firma ad hoc, non notarizzata da Apple. Se macOS blocca l’apertura, puoi autorizzarla in Impostazioni di Sistema → Privacy e sicurezza → Apri comunque, dopo averne verificato la provenienza. Il checksum SHA-256 è allegato alla release.

Autorizza Microfono e Accessibilità. Nelle impostazioni Tastiera di macOS scegli «Nessuna azione» per il tasto Fn, per evitare l’apertura del selettore emoji.

## Funzioni

- Tieni premuto Fn per dettare e rilascia per inserire il testo nel campo attivo. Scorciatoia modificabile nelle impostazioni.
- Notch traslucido, trascinabile e configurabile per monitor; pulsanti di registrazione e appunti al passaggio del mouse.
- Cronologia appunti attivabile: doppio Shift, frecce per scegliere, Invio per copiare e incollare. Conserva fino a 40 testi/link in memoria fino alla chiusura dell’app.
- Dashboard con statistiche reali e trascrizioni paginate, dieci righe per pagina.
- Notetaker nella dashboard o in una finestra dedicata aperta dal menu di sistema. Registrazione continua fino a Stop, ricerca, salvataggio locale e swipe per eliminare con conferma.
- Riscrittura delle note tramite Claude Code, mantenendo originale e risultato separati. Richiede la CLI `claude` e l’accesso con `claude auth login`; si applicano i limiti e le condizioni del proprio account. Nessuna chiave API richiesta dalla dettatura.
- Avvio al login, lingua, suoni e arresto per silenzio configurabili. Le note registrate non si interrompono durante le pause.

La dettatura usa SpeechAnalyzer/SpeechTranscriber di Apple: il modello della lingua viene scaricato al primo utilizzo se necessario. Non garantiamo un tempo fisso di trascrizione; la latenza è misurata nella dashboard. L’inserimento richiede un campo testuale con cursore attivo, non soltanto il puntatore sopra il campo. Senza destinazione valida, la trascrizione resta copiabile nel notch.

L’audio non viene salvato. Trascrizioni e statistiche sono in `~/Library/Application Support/MyWispr/usage.json`; note e versioni riscritte in `~/Library/Application Support/MyWispr/notes.json`. Premendo Riscrivi con Claude il testo della nota viene inviato al servizio tramite la CLI.

## Sviluppo e release

Serve Xcode con SDK macOS 26 e Swift 6.

```sh
./build.sh
open build/MyWispr.app
```

Per creare il DMG e il checksum:

```sh
./release.sh
```

La distribuzione pubblica senza avvisi Gatekeeper richiede un certificato Developer ID e notarizzazione Apple. I certificati Apple Development non sostituiscono Developer ID per questo scopo. La compilazione verifica il codice; microfono e inserimento vanno provati su un Mac con permessi autorizzati.

Le icone Lucide sono distribuite secondo la licenza riportata in `THIRD_PARTY/Lucide-LICENSE`.
