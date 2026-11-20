<a id="top"></a>

# NDM virsh KVM Backup Restore

[English](README.md) · **Italiano**

![Bash](https://img.shields.io/badge/bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)
![Version](https://img.shields.io/badge/version-1.2.0-informational)
![Dependencies](https://img.shields.io/badge/dependencies-libvirt%2C%20qemu--img%2C%20python3-lightgrey)

Un unico script con menu per **fare il backup di una macchina virtuale
libvirt/KVM spenta, dimostrare che il backup si avvia, ripristinarla e
gestire i backup**, senza snapshot e senza mai sovrascrivere nulla.

Versione **1.2.0**, pubblicata il 2026-11-20. Licenza **AGPL-3.0-or-later**.

## Indice

- [Funzioni](#features)
- [Requisiti](#requirements)
- [Avvio rapido](#quick-start)
- [Uso](#usage)
- [Menu interattivo](#interactive-menu)
- [Configurazione](#configuration)
- [Avvio di prova: overlay o copia](#test-boot-overlay-or-copy)
- [Ripristino: percorsi originali o copia rinominata](#restore-original-paths-or-a-renamed-copy)
- [Spazio libero](#free-space)
- [Backup su un disco esterno](#backups-on-an-external-disk)
- [Cosa contiene un backup](#what-a-backup-contains)
- [Backup più piccoli con fstrim](#smaller-backups-with-fstrim)
- [Proprietari e permessi](#ownership-and-permissions)
- [Il ciclo completo](#the-whole-cycle)
- [Cose a cui fare attenzione](#things-to-watch-out-for)
- [Codici di uscita](#exit-codes)
- [Controlli di qualità](#quality-checks)
- [Cronologia delle versioni](#version-history)
- [Esclusione di responsabilità](#disclaimer)
- [Licenza](#license)
- [Autore](#author)

---

<a id="features"></a>
## Funzioni

- **Solo backup coerenti**: una VM viene salvata solo da spenta, e il
  backup viene scartato (rinominato `.INVALID`) se la VM viene avviata
  durante il backup o se il backup si interrompe a metà. Non viene mai
  creato uno snapshot.
- **Non tira mai a indovinare**: ogni disco viene letto nel formato
  dichiarato dalla sua definizione, e un backup i cui dischi rimandano
  ad altri file, o la cui cartella contiene file non elencati nei
  checksum, viene rifiutato.
- **Qualsiasi disco locale**: file, dispositivi a blocchi (LVM) e volumi
  di storage pool, ovunque si trovino. Ogni disco diventa un qcow2
  autonomo; una catena di snapshot esterni viene appiattita.
- **Tutto ciò che serve alla VM**: definizione, dischi, variabili UEFI
  (NVRAM) e stato del TPM emulato (Windows 11 e guest simili).
- **Compresso, ma sempre utilizzabile**: ogni disco è compresso dentro
  il suo qcow2 (zstd di default, senza perdita), così il backup occupa
  meno spazio e si può comunque verificare e avviare in prova senza
  scompattare nulla.
- **Identità dimostrata**: subito dopo la scrittura di ogni disco,
  `qemu-img compare` verifica che la VM veda esattamente lo stesso
  contenuto del disco originale; un ripristino viene confrontato con il
  backup allo stesso modo.
- **Checksum**: ogni file di un backup è registrato in `SHA256SUMS` e
  controllato a ogni verifica, avvio di prova e ripristino.
- **Avvio di prova**: un backup viene avviato come VM di prova temporanea
  e separata, di default senza rete, per dimostrare che si avvia. Di
  default avvia i dischi del backup stesso, aperti in sola lettura, con
  le modifiche in un piccolo file overlay (nessuna copia, parte subito);
  l'alternativa è una copia completa. Il backup viene solo letto e poi
  verificato di nuovo; la VM originale non viene mai toccata.
- **Ripristino sicuro**: la VM torna con il suo nome, UUID e scheda di
  rete, ogni disco al suo percorso e nome di file originali; oppure come
  copia rinominata accanto all'originale. Ogni destinazione viene
  mostrata prima di un `yes` digitato, niente di esistente viene mai
  sovrascritto e la VM non viene avviata.
- **Spazio libero mostrato prima**: ogni scrittura mostra lo spazio che
  le serve, viene rifiutata se non c'è posto e chiede conferma quando
  lascerebbe il disco quasi pieno.
- **Cancellazione sicura**: vengono cancellate solo cartelle con la forma
  di un backup, con un avviso quando è l'ultimo backup di quella VM.
- **Menu interattivo** con una cartella dei backup per la sessione,
  oppure comandi semplici per gli script.
- **File di configurazione** letto come dati, mai eseguito, modificabile
  dal menu.
- **Funziona in qualsiasi lingua**: i messaggi di libvirt vengono letti
  nella locale C.

[Torna su](#top)

---

<a id="requirements"></a>
## Requisiti

| Requisito | Debian/Ubuntu | Fedora/RHEL | Arch | Perché |
|---|---|---|---|---|
| bash 4.4 o successiva | `bash` | `bash` | `bash` | lo script stesso |
| `virsh` | `libvirt-clients` | `libvirt-client` | `libvirt` | definizioni e stati delle VM, define/undefine |
| `qemu-img` 2.10 o successiva, 5.1 o successiva per zstd | `qemu-utils` | `qemu-img` | `qemu-img` | conversione, compressione, confronto e stima della dimensione dei dischi |
| `python3` | `python3` | `python3` | `python` | lettura e riscrittura della definizione XML |
| root, tramite `sudo` | `sudo` | `sudo` | `sudo` | immagini dei dischi, NVRAM e stato del TPM |
| `setfacl`, `getfacl` (solo avvio di prova overlay) | `acl` | `acl` | `acl` | far entrare l'utente dell'hypervisor nella cartella del backup durante la prova |

Tutto insieme:

```bash
# Debian, Ubuntu
sudo apt install libvirt-clients qemu-utils python3 sudo acl
# Fedora, RHEL e derivate
sudo dnf install libvirt-client qemu-img python3 sudo acl
# Arch, Manjaro
sudo pacman -S --needed libvirt qemu-img python sudo acl
```

Su un host che esegue già VM con virt-manager, la maggior parte è già
installata. A ogni avvio lo script controlla i comandi senza i quali non
può funzionare e, se ne manca uno, si ferma indicando il comando di
installazione per la distribuzione su cui gira (letta da
`/etc/os-release`); non installa mai nulla da solo. `setfacl`/`getfacl`
vengono controllati solo prima di un avvio di prova overlay.

Gli strumenti standard (`coreutils`, `findutils`, `util-linux`,
`gawk`/`mawk`, `sed`) si danno per presenti. Le VM sono quelle di sistema
di libvirt (`qemu:///system`), come le gestisce virt-manager.

Avviato senza root da un terminale, lo script lo dice e si riavvia da
solo tramite `sudo`, che chiede la password e rifiuta un utente non
autorizzato. Quando quell'esecuzione termina, anche con Ctrl-C o con la
chiusura del terminale, scarta le credenziali `sudo` in cache
(`sudo -k`): il `sudo` successivo su quel terminale chiede di nuovo la
password, anche se una era in cache prima dell'avvio dello script. Senza
terminale (un cron job, una pipe) si limita a fermarsi.

[Torna su](#top)

---

<a id="quick-start"></a>
## Avvio rapido

Il progetto è una cartella: lo script, la sua configurazione e, di
default, i backup (`backup/`). Mettila dove vuoi: sul disco dei backup
stesso, così i backup restano accanto allo strumento che li ha creati e
il disco funziona allo stesso modo su qualsiasi host, oppure in una
cartella come `/opt`. Solo quella cartella contiene qualcosa dello
strumento; le VM restano dove sono.

```bash
# Sul disco dei backup (vedi "Backup su un disco esterno")
sudo cp -r ndm_virsh-kvm-backup-restore /mnt/vm-backup/
sudo /mnt/vm-backup/ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.sh

# Oppure in /opt, con un collegamento facoltativo nel PATH
sudo cp -r ndm_virsh-kvm-backup-restore /opt/
sudo ln -s /opt/ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.sh /usr/local/bin/
sudo ndm_virsh-kvm-backup-restore.sh
```

Senza argomenti lo script apre il menu. Con i valori di default, i
backup vanno in `backup/` dentro la cartella del progetto. `BACKUP_DIR`
(menu `s`) li mette altrove: tienili fuori dal disco di sistema e dal
disco su cui stanno le VM, idealmente su uno storage cifrato. La prima
modifica crea `ndm_virsh-kvm-backup-restore.conf` dal `.conf.example`
incluso. Un collegamento nel `PATH` deve essere un collegamento, non una
copia: lo script cerca la configurazione accanto alla sua posizione
reale.

Alcuni modi di copiare la cartella perdono il bit di esecuzione: il
download da un editor ("Download..." di VS Code), uno zip, molti client
SFTP grafici. `git clone`, `rsync -a` e `scp -p` lo mantengono. Se
`sudo ./ndm_virsh-kvm-backup-restore.sh` risponde "command not found" o
"Permission denied", ripristinalo una volta:

```bash
chmod +x ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.sh
```

[Torna su](#top)

---

<a id="usage"></a>
## Uso

```text
# Menu interattivo
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE]

# Modalità comandi (senza menu, per gli script)
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] save DOMAIN [DEST_DIR]
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] verify BACKUP_DIR
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] test-start BACKUP_DIR [--overlay|--copy] [--with-network] [--test-dir DIR]
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] test-clean DOMAIN
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] restore BACKUP_DIR [DISK_DIR] [--copy]
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] delete BACKUP_DIR

# Aiuto e versione (senza sudo)
ndm_virsh-kvm-backup-restore.sh -h | --help
ndm_virsh-kvm-backup-restore.sh -V | --version
```

`DOMAIN` è il nome della VM come lo mostrano virt-manager o
`virsh list --all`. `BACKUP_DIR` è una cartella creata da `save`:
`DEST_DIR/DOMAIN-<data>-<ora>`.

### Comandi

| Comando | Cosa fa |
|---|---|
| `save DOMAIN [DEST_DIR]` | Salva una VM spenta in una nuova cartella `DEST_DIR/DOMAIN-<data>-<ora>`. Senza `DEST_DIR`, il `BACKUP_DIR` della configurazione in uso. Una destinazione mancante viene creata, una esistente viene usata così com'è; se lì c'è già un backup con lo stesso nome, non viene fatto nulla. Lo spazio libero viene controllato prima. |
| `verify BACKUP_DIR` | Controlla ogni file di un backup rispetto a `SHA256SUMS`, e che la cartella non contenga file non elencati in `SHA256SUMS`. |
| `test-start BACKUP_DIR [--overlay\|--copy] [--with-network] [--test-dir DIR]` | Avvia il backup come VM di prova `zztest-restore-DOMAIN` (prefisso impostato da `TEST_PREFIX`), contrassegnata come VM di prova nella sua descrizione libvirt. `--overlay` (default, `TEST_MODE`) avvia i dischi del backup stesso in sola lettura, `--copy` una loro copia: vedi [Avvio di prova](#test-boot-overlay-or-copy). I suoi file vanno in `DIR/zztest-restore-DOMAIN/` (default `TEST_BASE_DIR`, altrimenti accanto ai dischi originali). Nessuna rete senza `--with-network`, che viene rifiutato mentre la VM originale è in esecuzione. La VM di prova non riceve mai i dispositivi host in passthrough né le cartelle condivise dell'host dell'originale. |
| `test-clean DOMAIN` | Ferma e rimuove la VM di prova di `DOMAIN` e i suoi file. Rifiutato per una VM senza il contrassegno di prova, qualunque sia il suo nome. Dopo una prova overlay restituisce i dischi del backup al proprietario che avevano prima, `0600`, toglie l'accesso dato all'utente dell'hypervisor e verifica di nuovo il backup. Non tocca mai la VM originale. |
| `restore BACKUP_DIR [DISK_DIR] [--copy]` | Definisce di nuovo la VM dal backup, con il suo nome, UUID e scheda di rete, ogni disco al suo percorso e nome di file originali. Con `--copy`, una copia rinominata `restore-DOMAIN` (prefisso `RESTORE_PREFIX`) con nuovi UUID e indirizzo MAC, dischi `restore-<nome file>` accanto agli originali. `DISK_DIR` mette invece i dischi lì, con i loro nomi originali. Mostra ogni destinazione e chiede `yes`; qualsiasi destinazione esistente lo ferma. La VM non viene avviata. Vedi [Ripristino](#restore-original-paths-or-a-renamed-copy). |
| `delete BACKUP_DIR` | Cancella un backup dopo aver chiesto di digitare `yes`. |

### Opzioni

| Opzione | Descrizione |
|---|---|
| `-c FILE`, `--config FILE` | Usa `FILE` invece della configurazione accanto allo script. |
| `-h`, `--help` | Aiuto completo, con ogni comando, la configurazione e un esempio. |
| `-V`, `--version` | Versione, data di pubblicazione, copyright e licenza. |

[Torna su](#top)

---

<a id="interactive-menu"></a>
## Menu interattivo

Avvia lo script senza un comando (il programma parla inglese):

```text
NDM virsh KVM Backup Restore 1.2.0 - KVM virtual machine backups
  Backups folder: /mnt/vm-backup/ndm_virsh-kvm-backup-restore/backup
  Configuration:  /mnt/vm-backup/ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.conf

  1) Back up a VM                           (save)
  2) Verify a VM backup                     (verify)
  3) Test-boot a VM backup                  (test-start)
     starts a temporary test VM from the backup (overlay or copy);
     the backup is only read, the original VM is not touched
  4) Remove the test VM started by 3        (test-clean)
     deletes only the temporary test VM and its files
  5) Restore a VM from its backup           (restore)
     back to its original disk paths, same name and identity
  6) Restore as a renamed copy              (restore --copy)
     restore-<vm>, new identity, next to the original
  7) Delete a VM backup                     (delete)
  f) Change the backups folder for this session
  s) Settings (saved in the configuration file)
  h) Show the help
  v) Show the version
  q) Quit
```

- **Backup** elenca ogni VM con il suo stato. Anche quelle in esecuzione
  vengono mostrate, segnate "shut it down first", e rifiutate se
  scelte. Lo spazio necessario viene mostrato prima della conferma.
- **Verifica, avvio di prova, ripristino, cancellazione** elencano i
  backup della cartella dei backup, dal più recente, con la loro
  dimensione, segnando quelli la cui VM esiste ancora.
- **Avvio di prova** chiede la cartella di prova (Invio: `TEST_BASE_DIR`,
  altrimenti accanto ai dischi originali), poi la modalità, mostrando per
  entrambe lo spazio necessario e quello libero, e se l'overlay è
  possibile lì:

  ```text
  | Test mode (Enter for o, from TEST_MODE):
  | o) overlay  boots the backup's own disks, read-only;
  |            what the test VM writes goes to a small file
  |            space: about 1.0GiB in /home/shared/VMs/kvm (120.0GiB free)
  |            backup reachable by the hypervisor: yes
  | c) copy     boots a copy of the backup, which is only read once
  |            space: about 48.2GiB in /home/shared/VMs/kvm (120.0GiB free)
  ```

  Un overlay non possibile viene segnato con il motivo e non si può
  scegliere; lo script non cambia mai modalità da solo.
- **Ripristino** (5) e **ripristino come copia rinominata** (6) chiedono
  una cartella per i dischi solo quando una cartella originale non
  esiste su questo host, poi mostrano ogni file che scriveranno e
  chiedono `yes`.
- Dopo ogni azione, Invio riporta al menu. Dentro un'azione, `q` torna
  al menu; nel menu principale esce.
- La cartella dei backup viene dalla configurazione; `f` la cambia solo
  per la sessione corrente, `s` cambia la configurazione.

[Torna su](#top)

---

<a id="configuration"></a>
## Configurazione

Il file di configurazione ha il nome dello script con `.conf` e sta
nella cartella dello script, anche quando lo script viene avviato
tramite un collegamento. `-c FILE` ne usa un altro. Un file o una chiave
mancanti prendono il valore di default.

Il progetto include `ndm_virsh-kvm-backup-restore.conf.example`, con
ogni chiave, il suo default e un commento. Il vero `.conf` resta fuori
da git: copia l'esempio e modificalo, oppure lascia che il menu (`s`) lo
crei dall'esempio alla prima modifica.

Il file viene **letto come dati, mai eseguito**: una riga `KEY=value`
per impostazione, `#` per i commenti, il valore facoltativamente tra
virgolette. I valori che contengono virgolette, backslash, `$` o
backtick vengono rifiutati, così come le chiavi sconosciute, con il
numero di riga. Il menu (`s`) cambia un'impostazione alla volta e
mantiene i commenti. Passare `BACKUP_OWNER` a `user` da lì mostra prima
i pericoli e richiede un `yes` digitato.

| Chiave | Default | Descrizione |
|---|---|---|
| `BACKUP_DIR` | `./backup` | Cartella dei backup. Un percorso relativo parte dalla cartella del file di configurazione; `~` è la home dell'utente che ha eseguito `sudo`. La cartella `backup/` di default è inclusa nel progetto (il suo contenuto è ignorato da git); qualsiasi altra cartella viene creata, dopo averlo chiesto, al primo backup. |
| `BACKUP_OWNER` | `user` | `user`: l'intero backup, dischi delle VM compresi, appartiene all'utente che ha eseguito `sudo` ed è leggibile senza `sudo`. `root`: tutto appartiene a root. Leggi i pericoli in [Proprietari e permessi](#ownership-and-permissions) prima di scegliere. |
| `COMPRESS` | `zstd` | Compressione dentro il qcow2 di ogni disco del backup: `zstd` (QEMU 5.1 o successiva), `zlib` (QEMU più vecchie) o `none`. Senza perdita. Il backup resta utilizzabile direttamente; il ripristino riscrive i dischi non compressi. |
| `COMPARE` | `yes` | `yes`: dopo la scrittura di ogni disco, `qemu-img compare` dimostra che la VM vede lo stesso contenuto dell'originale, e qualsiasi differenza segna il backup come `.INVALID`. Legge entrambi i dischi per intero, quindi circa raddoppia il tempo del backup. `no`: lo salta. |
| `LIBVIRT_URI` | `qemu:///system` | Connessione a libvirt, solo locale: `qemu:///system` o `qemu:///session` (altri trasporti possono far eseguire un comando a libvirt). Non è la posizione dei dischi: i dischi si trovano dalla definizione di ogni VM. |
| `TEST_PREFIX` | `zztest-restore-` | Prefisso del nome della VM di prova. Lettere, cifre, `.`, `_` e `-`, che termina con `-`. Le VM di prova hanno anche un contrassegno nella loro descrizione libvirt, e vengono rimosse solo le VM contrassegnate, quindi una VM vera il cui nome inizia con il prefisso è al sicuro. Rimuovi le VM di prova esistenti prima di cambiarlo: il menu elenca solo quelle con il prefisso attuale. |
| `TEST_BASE_DIR` | (vuoto) | Cartella che contiene i file della VM di prova. Vuoto: accanto ai dischi della VM originale, altrimenti la cartella del pool `default`, altrimenti `/var/lib/libvirt/images`. Il menu la chiede a ogni prova con questo valore come default; `--test-dir` la sostituisce da riga di comando. |
| `TEST_NETWORK` | `no` | Risposta di default nel menu a "avviare la VM di prova con una scheda di rete?". `no`: nessuna rete, così la VM originale può continuare a girare nello stesso momento. `yes`: stessa rete dell'originale, rifiutato mentre l'originale è in esecuzione. |
| `TEST_MODE` | `overlay` | Modalità di default dell'avvio di prova: `overlay` (i dischi del backup stesso, in sola lettura) o `copy`. Vedi [Avvio di prova](#test-boot-overlay-or-copy). |
| `RESTORE_PREFIX` | `restore-` | Prefisso del nome della VM e dei nomi dei file dei dischi di un ripristino come copia rinominata. Lettere, cifre, `.`, `_` e `-`, che termina con `-`. |

[Torna su](#top)

---

<a id="test-boot-overlay-or-copy"></a>
## Avvio di prova: overlay o copia

Un avvio di prova dimostra che si avvia il **backup**: la VM originale
si avvia già. Insieme a `save` (il backup ha lo stesso contenuto
dell'originale, `qemu-img compare`) e a `restore` (il disco ripristinato
ha lo stesso contenuto del backup, confrontato allo stesso modo), chiude
la catena delle prove.

In entrambe le modalità il contenuto del backup non viene mai scritto:
viene solo letto.

| | Overlay (default) | Copia |
|---|---|---|
| Cosa si avvia | i dischi del backup stesso, aperti in sola lettura; ciò che la VM di prova scrive va in un piccolo file overlay | una copia dei dischi del backup |
| Spazio nella cartella di prova | circa 1 GiB, che cresce con ciò che la VM di prova scrive | la dimensione del backup, anch'essa in crescita |
| Avvio | subito | dopo la copia dell'intero backup |
| Disco del backup durante la prova | deve restare collegato | serve solo per la copia |
| Velocità della VM di prova | legge il backup (più lenta su un disco USB) | legge la cartella di prova |
| Dove può stare il backup | l'utente dell'hypervisor deve poter attraversare ogni cartella sopra di esso | ovunque |

Come l'overlay raggiunge il backup: QEMU gira con un proprio utente
(`libvirt-qemu` su Debian). libvirt gli affida i file dei dischi mentre
la VM è in esecuzione, ma non cambia mai le cartelle. Quindi:

- la **cartella del backup** stessa (`0750` con `BACKUP_OWNER=user`): lo
  script dà a quell'utente un'ACL di attraversamento per la durata della
  prova, e `test-clean` la toglie;
- **ogni cartella sopra di essa** deve già lasciar passare quell'utente
  (una `x` per gli altri in `ls -ld`, oppure `namei -l <cartella del
  backup>` per l'intero percorso). Lo script lo controlla prima, indica
  la cartella che blocca e non cambia mai una cartella che non ha
  creato. Una cartella accanto ai dischi delle VM funziona sempre,
  perché le VM girano già da lì. Blocchi comuni: una cartella home `0700`
  o `0750`, e un disco montato dal desktop sotto `/media/<utente>/` (vedi
  [Backup su un disco esterno](#backups-on-an-external-disk)).

Dopo una prova overlay, `test-clean` restituisce i dischi del backup al
proprietario che avevano prima della prova, `0600` (anche libvirt li
restituisce quando la VM si ferma, ma un'interruzione di corrente
durante la prova può lasciarli al suo utente), toglie l'ACL e verifica
di nuovo il backup rispetto a `SHA256SUMS`, come prova che è invariato.
Se in quel momento il disco del backup non è collegato, dice cosa
eseguire quando torna.

Se `test-start` fallisce o viene interrotto (Ctrl-C, terminale chiuso)
prima che la VM di prova esista, rimuove la sua cartella e annulla l'ACL
da solo; se un passo di questo annullamento fallisce, stampa i comandi
per completarlo a mano. Solo `kill -9` o un'interruzione di corrente lo
saltano.

L'overlay richiede che la cartella del backup abbia il nome che le dà
`save` (`<vm>-<data>-<ora>`), e che anche la cartella che contiene la
cartella di prova sia raggiungibile dall'utente dell'hypervisor;
altrimenti il menu lo segna come non possibile e dice perché.

[Torna su](#top)

---

<a id="restore-original-paths-or-a-renamed-copy"></a>
## Ripristino: percorsi originali o copia rinominata

| | `restore` (menu 5) | `restore --copy` (menu 6) |
|---|---|---|
| VM | il suo nome, UUID e scheda di rete originali | `restore-<nome>` (`RESTORE_PREFIX`), nuovi UUID e indirizzo MAC |
| Dischi | al loro percorso originale: stessa cartella, stesso nome di file | accanto agli originali, come `restore-<nome file>` |
| Uso | il vero ripristino, una volta eliminata la VM guasta | confrontare il backup con l'originale, fianco a fianco |
| Rifiutato quando | è definita una VM con quel nome o UUID, o esiste un file di destinazione | è definita una VM con il nome della copia, o esiste un file di destinazione |

Per esempio, una VM il cui disco è `/home/shared/VMs/kvm/MYVM.qcow2`:

- `restore` scrive `/home/shared/VMs/kvm/MYVM.qcow2` e definisce `MYVM`.
  Se il vecchio file è ancora lì, il ripristino si ferma: rinominalo
  (per esempio in `MYVM.qcow2.broken`) o rimuovilo prima, oppure usa
  `--copy`.
- `restore --copy` scrive `/home/shared/VMs/kvm/restore-MYVM.qcow2` e
  definisce `restore-MYVM`. Dentro, la copia ha ancora hostname,
  indirizzo IP e chiavi dell'originale: non avviarle entrambe sulla
  stessa rete.

Prima di scrivere qualsiasi cosa, lo script mostra ogni file che
scriverà e chiede `yes`. Niente di esistente viene mai sovrascritto.
Poiché gira come root e i percorsi vengono dal backup, ogni cartella
originale deve esistere, essere un percorso assoluto e non contenere
collegamenti.

**Su un altro host** (la cartella originale non esiste): lo script lo
dice e si ferma. Indica una cartella per i dischi, `restore BACKUP_DIR
DISK_DIR` (il menu la chiede): lì i dischi mantengono i loro nomi di
file originali.

I dischi che erano dispositivi a blocchi (LVM) o volumi di pool tornano
come file chiamati `<nome>-<dev>.qcow2`, in `DISK_DIR` o accanto al
primo disco.

[Torna su](#top)

---

<a id="free-space"></a>
## Spazio libero

Backup, avvio di prova e ripristino mostrano, prima di scrivere
qualsiasi cosa, lo spazio necessario e quello libero su ogni disco su
cui scrivono:

- spazio insufficiente per il necessario più il 10%: non viene fatto
  nulla, e il messaggio dice cosa cambiare (un'altra cartella,
  `BACKUP_DIR`, `--test-dir` o `TEST_BASE_DIR`, `DISK_DIR`);
- spazio sufficiente, ma resterebbe libero meno del 10% di quel disco:
  lo script avvisa e chiede di digitare `yes`. Quando un disco si
  riempie, libvirt mette in pausa le VM in esecuzione con dischi su di
  esso: una copia di prova accanto ai dischi delle VM può fermare la VM
  originale stessa. Senza terminale si ferma.

La stima del backup è la dimensione non compressa, quindi il backup di
solito occupa meno. I file di una VM di prova crescono mentre è in
esecuzione: tieni le prove brevi.

[Torna su](#top)

---

<a id="backups-on-an-external-disk"></a>
## Backup su un disco esterno

Un backup sullo stesso disco delle VM non sopravvive a quel disco: va
bene per una prima copia veloce, non come unica copia. Un disco esterno
funziona meglio con l'intera cartella del progetto sopra (vedi
[Avvio rapido](#quick-start)).

- **Filesystem: ext4 dentro una cifratura LUKS.** È la cifratura che
  protegge un disco perso o rubato: proprietari e permessi no (vedi
  [Proprietari e permessi](#ownership-and-permissions)). Non exFAT o
  NTFS: non hanno proprietari né permessi, quindi ogni utente dell'host
  potrebbe leggere i dischi dei backup, e lo stato del TPM perde il suo
  proprietario.
- **Un punto di mount fisso**, non quello automatico del desktop. Il
  desktop monta i dischi sotto `/media/<utente>/<etichetta>/`;
  `/media/<utente>` lascia entrare solo quell'utente, quindi una prova
  overlay non può raggiungere il backup, e il percorso cambia con
  l'etichetta. Una riga in `/etc/fstab` con l'UUID del disco dà un
  percorso stabile e permessi che dipendono solo dal disco stesso:

  ```text
  # trova l'UUID con: lsblk -f
  UUID=<uuid>  /mnt/vm-backup  ext4  defaults,nofail,noatime  0  2
  ```

  `nofail` permette all'host di avviarsi senza il disco. Con LUKS,
  aggiungi una riga in `/etc/crypttab` e usa invece l'UUID del
  dispositivo aperto. Non aggiungere `noexec`: lo script sul disco non
  partirebbe.
- **Permessi sul disco**: un ext4 appena creato ha la cartella
  principale `root 0755`, che lascia passare l'utente dell'hypervisor;
  le cartelle che crei sopra mantengono il solito `0755`. Le cartelle
  dei backup restano `0750`/`0700`: la prova overlay le apre con un'ACL
  solo per la sua durata (ext4 supporta le ACL senza opzioni
  aggiuntive).

Uno storage pool di libvirt sulla cartella dei backup non serve e non è
consigliato: non cambia i permessi delle cartelle, e mostra i dischi del
backup in virt-manager come volumi che si possono cancellare o collegare
per errore.

[Torna su](#top)

---

<a id="what-a-backup-contains"></a>
## Cosa contiene un backup

```text
myvm-20261018-141829/
  domain.xml            definizione della VM (senza password della console)
  disk-vda.qcow2        un qcow2 autonomo per disco, compresso internamente
  disk-vda.info.txt     qemu-img info del disco originale
  nvram.fd              variabili UEFI (solo VM UEFI)
  tpm/                  stato del TPM emulato (solo se la VM ne ha uno)
  sources.txt           da dove viene ogni file
  SHA256SUMS            checksum di tutto quanto sopra
```

Le password della console (VNC/SPICE) non vengono salvate: se le usi,
impostale di nuovo dopo un ripristino.

[Torna su](#top)

---

<a id="smaller-backups-with-fstrim"></a>
## Backup più piccoli con fstrim

Quando un file viene cancellato dentro la VM, il guest segna i suoi
blocchi come liberi, ma il disco virtuale non lo sa: quei blocchi
contengono ancora i vecchi dati e vengono copiati in ogni backup. Dire
al disco quali blocchi sono liberi rende il backup più piccolo, spesso
più di quanto faccia la compressione.

Dentro la VM, subito prima di spegnerla per un backup:

```bash
sudo fstrim -av     # Linux: esegue il trim di ogni filesystem montato, stampa quanto
sudo poweroff
```

Sui guest Windows, Ottimizza unità (`defrag C: /L` da un prompt di
amministratore) fa la stessa cosa.

Funziona quando il disco virtuale lascia passare le richieste di
discard: in virt-manager, le opzioni Prestazioni del disco con la
modalità Discard impostata su `unmap` (`discard='unmap'` nel `<driver>`
del disco), su un bus `virtio-scsi` o `virtio` (VirtIO, QEMU recenti). Se
`fstrim` risponde "the discard operation is not supported", il disco non
lo lascia passare e il trim non ha effetto sul backup. Eseguirlo è
comunque innocuo.

[Torna su](#top)

---

<a id="ownership-and-permissions"></a>
## Proprietari e permessi

Con `BACKUP_OWNER=user`, dove `USER` è chi ha eseguito `sudo`:

| Cosa | Proprietario | Modo |
|---|---|---|
| Cartella del backup, e una cartella dei backup creata dallo script | `USER` | `0750` |
| `domain.xml`, `sources.txt`, `*.info.txt`, `SHA256SUMS` | `USER` | `0640` |
| `disk-*.qcow2`, `nvram.fd` | `USER` | `0600` |
| `tpm/` | come l'originale | come l'originale |

Con `BACKUP_OWNER=root`, o quando viene eseguito come root senza
`sudo`, ogni riga tranne `tpm/` diventa di root: cartelle `0700`, file
`0600`.

Una cartella dei backup già esistente non viene mai modificata.

### Cosa protegge il proprietario, e cosa no

Proprietari e permessi valgono solo sull'host che li applica. Chi ha in
mano il disco del backup lo monta su una macchina dove è root, e legge
tutto, qualunque cosa dicano i proprietari. **Contro un disco perso o
rubato protegge solo la cifratura: tieni i backup, e ogni loro copia,
su LUKS.** Vale con entrambi i valori di `BACKUP_OWNER`.

Sull'host in esecuzione, il proprietario decide quali programmi possono
leggere i dischi delle VM senza `sudo`:

- **`BACKUP_OWNER=user`**: gli strumenti a livello utente lavorano
  sull'intero backup, dischi compresi. Uno strumento di backup che gira
  come `USER` (Back In Time, per esempio) può copiare i backup su un
  altro disco. **Il pericolo**: lo può fare anche qualsiasi altra cosa
  che gira come `USER`. Un'estensione del browser malevola, un programma
  compromesso, un client di sincronizzazione (Nextcloud, Dropbox) che
  carica la cartella, o uno strumento di backup che la copia su uno
  storage non cifrato ottengono tutti ogni chiave, password e segreto
  memorizzati nelle VM, senza `sudo` e senza alcuna richiesta.
- **`BACKUP_OWNER=root`**: leggere i dischi richiede `sudo` o uno
  strumento che gira come root (per esempio Back In Time in modalità
  root, che mantiene i proprietari). Un programma che gira come `USER`
  non può leggerli direttamente. È una barriera debole: un programma che
  controlla la sessione dell'utente può aspettare la password di `sudo`.
  Ferma le fughe casuali, non un attaccante determinato.

Scegli `root` se niente di ciò che gira come `USER` deve leggere i
backup.

I backup fatti da 1.1.0 o precedenti hanno dischi e NVRAM di root. Per
darli a `USER`, come fa 1.2.0 con `BACKUP_OWNER=user`:

```sh
sudo chown USER: /percorso/dei/backup/*/disk-*.qcow2 /percorso/dei/backup/*/nvram.fd
```

### Dischi ripristinati e di prova

I dischi ripristinati e quelli della VM di prova sono di root `0600`,
come quelli che crea virt-manager, qualunque cosa dica `BACKUP_OWNER`:
libvirt li dà al proprio utente mentre la VM è in esecuzione e li
riprende quando si ferma. Durante una prova overlay succede lo stesso ai
dischi del backup, e la cartella del backup riceve un'ACL di
attraversamento per quell'utente; `test-clean` restituisce i dischi al
proprietario che avevano prima della prova e toglie l'ACL.

[Torna su](#top)

---

<a id="the-whole-cycle"></a>
## Il ciclo completo

Gli stessi passi sono disponibili dal menu (opzioni da 1 a 6).

```bash
# 0. Dentro la VM: libera lo spazio dei file cancellati, poi spegnila
sudo fstrim -av
sudo poweroff

# 1. Backup
sudo ndm_virsh-kvm-backup-restore.sh save myvm /mnt/backup
#    oppure, nel BACKUP_DIR della configurazione:
#    sudo ndm_virsh-kvm-backup-restore.sh save myvm
#    -> /mnt/backup/myvm-20261018-141829

# 2. Verifica il backup
sudo ndm_virsh-kvm-backup-restore.sh verify /mnt/backup/myvm-20261018-141829

# 3. Dimostra che si avvia, poi rimuovi la VM di prova
sudo ndm_virsh-kvm-backup-restore.sh test-start /mnt/backup/myvm-20261018-141829
#    (overlay di default; --copy per una copia, --test-dir DIR per i suoi file)
#    virt-manager: apri zztest-restore-myvm (TEST_PREFIX + nome),
#    accedi dalla console, spegnila
sudo ndm_virsh-kvm-backup-restore.sh test-clean myvm

# ... più tardi, la VM è persa o guasta ...

# 4. Verifica di nuovo il backup prima di usarlo
sudo ndm_virsh-kvm-backup-restore.sh verify /mnt/backup/myvm-20261018-141829

# 5. Rimuovi ciò che resta della VM guasta, se c'è
#    virt-manager: clic destro, Elimina (oppure: sudo virsh undefine myvm),
#    e rinomina o rimuovi il suo vecchio file del disco (restore non lo sovrascrive mai)

# 6. Ripristinala, ai percorsi originali dei dischi
sudo ndm_virsh-kvm-backup-restore.sh restore /mnt/backup/myvm-20261018-141829
#    oppure, mantenendo l'originale, come restore-myvm accanto a essa:
#    sudo ndm_virsh-kvm-backup-restore.sh restore /mnt/backup/myvm-20261018-141829 --copy
#    oppure, su un host senza la cartella originale:
#    sudo ndm_virsh-kvm-backup-restore.sh restore /mnt/backup/myvm-20261018-141829 /srv/vms

# 7. Avviala e controllala; il backup resta utilizzabile per la prossima volta
sudo virsh start myvm
sudo ndm_virsh-kvm-backup-restore.sh verify /mnt/backup/myvm-20261018-141829
```

[Torna su](#top)

---

<a id="things-to-watch-out-for"></a>
## Cose a cui fare attenzione

- **Un backup contiene l'intera VM**: ogni chiave, password e segreto
  memorizzati al suo interno. Tieni i backup, e ogni loro copia, solo su
  storage cifrato; con `BACKUP_OWNER=user` qualsiasi programma che gira
  come te può leggerli (vedi
  [Proprietari e permessi](#ownership-and-permissions)). Non metterli
  mai in un commit (il `.gitignore` incluso esclude tutto ciò che è in
  `backup/` tranne il suo `.gitkeep`).
- **Spegni la VM dall'interno** (o Spegni in virt-manager) prima di un
  backup. Forza spegnimento equivale a togliere la corrente: il backup
  è allora coerente solo come dopo un crash.
- **La VM di prova è un clone**: stesso indirizzo IP, chiavi e attività
  pianificate dell'originale. Senza rete non può entrare in conflitto
  con essa; con `--with-network`, tieni l'originale spenta fino a
  `test-clean`. Lo stesso vale per un ripristino con `--copy`.
- **Tieni collegato il disco del backup durante una prova overlay**: se
  viene scollegato, la VM di prova si ferma; il backup in sé non viene
  danneggiato, viene solo letto.
- **Gli snapshot interni non vengono salvati**, solo lo stato attuale di
  ogni disco.
- **Un danno a un backup compresso costa di più**: un punto difettoso
  dello storage fa perdere un blocco compresso (64 KiB) invece di pochi
  byte. `verify` rileva entrambi i casi; tieni più di un backup e
  verificali ogni tanto. Imposta `COMPRESS=none` se questo compromesso
  non fa per te.
- **Il guadagno della compressione dipende dal contenuto**: ampio sui
  dischi di sistema, quasi nullo su dati già compressi (video, archivi).
  Vedi [Backup più piccoli con fstrim](#smaller-backups-with-fstrim).
- **Lo script gira come root**: chi può modificare lo script stesso può
  eseguire comandi come root. Tieni la cartella del progetto di
  proprietà di root se altri utenti possono accedere. Il file di
  configurazione si può lasciare scrivibile senza rischi: non viene mai
  eseguito.
- **I membri del gruppo `libvirt`** possono già raggiungere ogni disco
  delle VM tramite libvirt: se `USER` è uno di loro, dargli i backup
  (`BACKUP_OWNER=user`) non amplia ciò che quell'account può leggere su
  quell'host. Lo amplia invece per i programmi che girano come `USER`
  senza passare da libvirt (vedi
  [Proprietari e permessi](#ownership-and-permissions)).

[Torna su](#top)

---

<a id="exit-codes"></a>
## Codici di uscita

| Codice | Significato |
|---|---|
| `0` | Successo, o nulla fatto di proposito (risposta `q`, conferma rifiutata) |
| `1` | Qualsiasi errore: argomenti sbagliati, azione rifiutata, controllo fallito; il motivo è su stderr |

[Torna su](#top)

---

<a id="quality-checks"></a>
## Controlli di qualità

```bash
shellcheck ndm_virsh-kvm-backup-restore.sh
bash -n ndm_virsh-kvm-backup-restore.sh
```

Entrambi passano senza segnalazioni a ogni release. La CI li esegue a
ogni push, insieme a prove della riga di comando (aiuto, versione, uso
non valido, un file di configurazione che non deve mai essere eseguito)
e a un controllo che la versione sia la stessa nello script, in entrambi
i README, in `CHANGELOG.md` e in `CITATION.cff`.

[Torna su](#top)

---

<a id="version-history"></a>
## Cronologia delle versioni

Ogni release, con ciò che è cambiato per l'utente (in inglese):
[CHANGELOG.md](CHANGELOG.md).

[Torna su](#top)

---

<a id="disclaimer"></a>
## Esclusione di responsabilità

> Questo software legge e scrive dischi di macchine virtuali come root.
> Non sovrascrive mai un file esistente e cancella solo ciò che la
> documentazione qui sopra descrive, ma un backup vale quanto l'ultima
> volta in cui è stato verificato e avviato in prova. Prova i tuoi
> backup. Il software è fornito senza alcuna garanzia, nei limiti
> consentiti dalla legge.

[Torna su](#top)

---

<a id="license"></a>
## Licenza

Copyright (C) 2026 Nicola Davide Mannarelli - @nidamanx

Questo programma è software libero: puoi ridistribuirlo e/o modificarlo
secondo i termini della GNU Affero General Public License pubblicata
dalla Free Software Foundation, nella versione 3 della licenza o (a tua
scelta) in qualsiasi versione successiva. Vedi [LICENSE](LICENSE) o
<https://www.gnu.org/licenses/agpl-3.0.html>.

Quando distribuisci questo software, includi il testo completo della
licenza.

[Torna su](#top)

---

<a id="author"></a>
## Autore

Nicola Davide Mannarelli (@nidamanx)

[Torna su](#top)
