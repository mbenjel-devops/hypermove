# Hypermove

Outil local d'orchestration de migrations **VMware → Hyper-V** via SCVMM. Conçu pour tourner sur un jump server Windows chez le client, sans dépendance cloud.

L'opérateur fournit une liste de VMs (CSV). L'outil exécute des scripts PowerShell prédéfinis sur chaque VM, suit l'avancement dans SQLite et produit un rapport.

## Contenu du dépôt

```
hypermove/
└── migration-tool/     # Application principale
    ├── app.py          # API Flask (port 5000)
    ├── orchestrator.py # Moteur d'exécution séquentiel
    ├── config.yaml     # Paramètres et identifiants
    ├── scripts/        # Pipeline PowerShell (4 étapes)
    ├── templates/      # Interface web
    └── input/          # Exemple de liste VMs
```

## Démarrage rapide

```powershell
git clone https://github.com/mbenjel-devops/hypermove.git
cd hypermove\migration-tool
pip install -r requirements.txt
```

Éditer `config.yaml` (vCenter, SCVMM), puis :

```powershell
py -3 app.py
```

Ouvrir **http://127.0.0.1:5000**, importer un CSV et cliquer sur **Start**.

## Fonctionnalités

- Traitement **séquentiel** des VMs (une à la fois)
- Pipeline en 4 étapes : pré-migration → conversion V2V → post-migration → validation
- Interface web avec suivi en temps réel (rafraîchissement 5 s)
- Exclusion automatique des OS legacy (2000, 2003, 2008) avec approbation manuelle
- Retry automatique sur échec de conversion (3 tentatives, 5 min d'attente)
- Contrôles Pause / Stop (arrêt propre après l'étape en cours)
- Logs append-only et rapport JSON via API

## Prérequis

| Composant | Version |
|-----------|---------|
| Python | 3.10+ |
| PowerShell | 5.1+ |
| OS | Windows (jump server) |

Accès réseau requis vers vCenter et SCVMM.

## Documentation

La documentation complète (configuration, workflow, API, scripts PowerShell) se trouve dans **[migration-tool/README.md](migration-tool/README.md)**.

## Sécurité

- La VM source n'est jamais modifiée par l'orchestrateur (sauf action explicite dans un script)
- Les identifiants du `config.yaml` ne sont jamais écrits dans les logs
- Écritures SQLite transactionnelles
- Pas d'authentification (outil local, jump server uniquement)

## Licence

Usage interne / projet client.
