# My Wispr

Prima versione nativa macOS, SwiftUI + AppKit. Richiede Mac Apple Silicon e macOS 26 o successivo. Nessuna chiave API o dipendenza esterna.

## Avvio

Esegui `./build.sh`, poi apri `build/MyWispr.app`.

1. Premi **Abilita permessi** e autorizza Microfono e Accessibilità nelle Impostazioni di Sistema → Privacy e sicurezza. Se il tasto globale non viene rilevato, autorizza anche Monitoraggio input e riapri l’app.
2. In Impostazioni di Sistema → Tastiera, imposta «Premi il tasto fn per» su «Non fare nulla», per evitare conflitti con la dettatura Apple o il selettore emoji.
3. Posiziona il cursore in un campo di testo di un’altra app, tieni premuto **fn**, parla e rilascia. Alternativa: tieni premuto **⌥Spazio** (disattiva eventuali scorciatoie concorrenti).
4. Il menu con l’icona waveform permette di riaprire le statistiche. Chiudere la finestra lascia l’app attiva; «Esci» la termina.

## Comportamento e limiti

Il motore SpeechAnalyzer / SpeechTranscriber di macOS 26 riconosce la voce localmente durante la registrazione. Non richiede che Siri o la dettatura di sistema siano attivi. Il modello della lingua viene scaricato da Apple al primo avvio se manca; lo stato è mostrato nella finestra. Attendere «Modello locale pronto» prima di dettare. Al rilascio finalizza l’audio senza un timeout che possa troncare il testo; 1–2 secondi è un obiettivo da misurare, non una garanzia.

La righetta arrotondata in basso si espande con microfono e onde durante l’ascolto e si richiude al rilascio. Le onde reagiscono al livello del microfono; rispettano l’impostazione Riduci movimento. I permessi vengono ricontrollati ogni secondo. Dopo una nuova compilazione la firma ad hoc può invalidare i permessi: rimuovere la vecchia voce e autorizzare la nuova app in Privacy e sicurezza se necessario.

L’inserimento usa il campo di testo attivo tramite Accessibilità, oppure il normale comando Incolla per gli editor che non supportano la scrittura diretta. In questo caso gli appunti precedenti vengono ripristinati dopo 800 ms, salvo che l’utente abbia copiato altro nel frattempo. «Incolla inviato» indica l’invio del comando, non una conferma dell’editor. Se non c’è un campo attivo, manca Accessibilità o è cambiata l’app, il notch mostra una scheda di vetro con trascrizione, Copia e Chiudi. Non basta passare il puntatore sopra un campo: deve esserci il cursore di scrittura.

La dashboard Insights mostra solo dati reali: velocità media ponderata per durata, sessioni, parole totali, latenza, cronologia e attività giornaliera nelle ultime 12 settimane. Nessuna classifica, percentuale o categoria viene inventata. Le altre sezioni verranno aggiunte successivamente.

Gli audio non vengono salvati. Da questa versione, testo delle trascrizioni e statistiche vengono salvati localmente in `~/Library/Application Support/MyWispr/usage.json` e mostrati nella lista completa con Copia. Il testo delle vecchie sessioni non è recuperabile perché le versioni precedenti conservavano solo statistiche.

La registrazione si arresta dopo oltre 10 secondi consecutivi senza segnale significativo (soglia circa −45 dB RMS); i risultati vocali ricevuti aggiornano anche il rilevamento. Rumori forti possono mantenere attiva la registrazione. Il watchdog viene cancellato al termine della sessione.

## Verifica

Compilazione con Swift 6 e firma ad hoc. La prova end-to-end richiede i permessi macOS, una voce reale e un campo di destinazione: non è sostituita dalla compilazione. Verificare: italiano/inglese, rilascio rapido, nessuna parola, permessi negati, cambio app durante registrazione, inserimento in TextEdit/browser, riapertura e persistenza statistiche.

La firma ad hoc è adatta allo sviluppo locale. Una distribuzione pubblica richiede firma Developer ID e notarizzazione. Dopo una nuova compilazione macOS potrebbe richiedere di aggiornare i permessi di Accessibilità.
