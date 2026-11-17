# Distributed Systems – Kubernetes Multi-Cluster with Liqo

Progetto sperimentale dedicato all'analisi del comportamento di applicazioni a microservizi distribuite su più cluster Kubernetes, utilizzando **Liqo** per la gestione dell'offloading dei workload tra cluster.

L'obiettivo è valutare le prestazioni, i tempi di migrazione e la continuità del servizio in diversi scenari operativi, attraverso esperimenti riproducibili e strumenti di monitoraggio.

## Tecnologie utilizzate

- **Kubernetes** – Orchestrazione dei container e gestione dei workload.
- **Liqo** – Federazione dei cluster Kubernetes e offloading dei servizi.
- **Kind** – Creazione di cluster Kubernetes locali.
- **Online Boutique** – Applicazione dimostrativa a microservizi utilizzata come workload.
- **Locust** – Generazione del carico applicativo e raccolta delle metriche HTTP.
- **Prometheus e Grafana** – Monitoraggio delle risorse e delle prestazioni.
- **Bash e Python** – Automazione degli esperimenti, elaborazione dei dati e generazione dei grafici.

## Architettura

L'ambiente sperimentale è costituito da due cluster Kubernetes:

- **Consumer:** cluster di origine che ospita l'applicazione e gestisce l'offloading.
- **Provider:** cluster remoto che mette a disposizione risorse computazionali per l'esecuzione dei workload.

I cluster sono collegati mediante Liqo, che consente di eseguire Pod sul provider attraverso un nodo virtuale visibile dal consumer.

L'applicazione utilizzata è *Online Boutique*, composta da diversi microservizi che comunicano tra loro.

## Esperimenti

### 1. Workload Test

Valutazione delle prestazioni dell'applicazione con diversi livelli di utenti virtuali concorrenti.

Metriche analizzate:
- Throughput e failure rate.
- Latenza media e percentili P95/P99.
- Utilizzo di CPU e memoria dei Pod.
- Utilizzo delle risorse dei nodi Kubernetes.

### 2. Offloading a freddo

Misurazione del tempo necessario a trasferire i workload dal consumer al provider, senza un carico applicativo attivo durante la migrazione.

Vengono analizzati i tempi di readiness dei Deployment e il completamento della procedura di offloading.

### 3. Offloading a caldo

Migrazione dei servizi dal consumer al provider durante l'esecuzione di un carico applicativo generato tramite Locust.

L'esperimento permette di valutare l'impatto della migrazione su throughput, latenza e disponibilità dell'applicazione.

### 4. Unoffloading a caldo

Rientro dei workload dal provider al consumer mentre l'applicazione continua a ricevere richieste.

L'obiettivo è misurare i tempi di rientro e individuare eventuali interruzioni o degradazioni prestazionali durante la procedura.

### 5. Fault Tolerance

Simulazione di guasti nell'infrastruttura Kubernetes, con particolare attenzione al comportamento dei workload offloadati e alla capacità del sistema di reagire all'indisponibilità delle risorse remote.

Vengono monitorati lo stato dei Pod, dei nodi, dei Deployment e gli eventi Kubernetes durante il guasto.

## Organizzazione del progetto

Il repository è organizzato nelle seguenti directory principali:

```text
distributed_project/
├── configs/          # Configurazioni degli esperimenti e di Liqo
├── scripts/          # Script Bash e Python
│   ├── analysis/     # Elaborazione metriche e generazione grafici
│   └── workload_test/
├── results/          # Risultati e dati sperimentali
└── README.md
```

## Esecuzione degli esperimenti

Gli esperimenti sono automatizzati mediante script Bash e utilizzano file di configurazione condivisi.

Le principali configurazioni sono definite in:

```text
configs/exp_config.conf
configs/liqo_config.conf
```

Prima dell'esecuzione è necessario predisporre i cluster Kubernetes, configurare Liqo e verificare la disponibilità dei workload applicativi.

Gli script raccolgono metriche, eventi e snapshot dello stato del sistema, salvando i risultati nelle directory dedicate ai singoli esperimenti.

## Analisi dei risultati

I dati raccolti vengono elaborati mediante script Python per produrre:

- File CSV contenenti metriche aggregate.
- Grafici temporali delle prestazioni applicative.
- Confronti tra diverse configurazioni sperimentali.
- Tabelle riepilogative dei tempi di migrazione.
- Log degli eventi Kubernetes.

L'analisi consente di confrontare il comportamento dell'applicazione nelle configurazioni locali e multi-cluster, valutando vantaggi e limitazioni dell'utilizzo di Liqo.

## Obiettivo del progetto

Il progetto mira a fornire una valutazione sperimentale dell'utilizzo di Liqo in ambienti Kubernetes multi-cluster, con particolare attenzione a:

- Prestazioni applicative.
- Tempi di offloading e unoffloading.
- Continuità del servizio durante le migrazioni.
- Comportamento del sistema in presenza di guasti.
- Impatto della distribuzione dei workload sulle risorse infrastrutturali.

## Contesto

Progetto sviluppato nell'ambito di uno studio universitario sui **Sistemi Distribuiti**, con particolare riferimento all'orchestrazione multi-cluster e alla gestione dinamica dei workload Kubernetes.
