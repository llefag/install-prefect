# Prefect Worker Installer

Déploiement automatique d'un worker Prefect comme service systemd sécurisé.

## Installation

```bash
git clone https://github.com/VOTRE_USER/install_prefect.git
cd install_prefect

# Configurer les secrets
cp secrets.txt.example secrets.txt
nano secrets.txt  # Remplir vos valeurs

# Installer
cat secrets.txt | sudo ./install.sh
```

## Secrets requis

| Variable | Description |
|----------|-------------|
| `PREFECT_API_URL` | URL de l'API Prefect |
| `PREFECT_API_KEY` | Clé API (pnu_...) |
| `WORK_POOL` | Nom du work pool |

## Options

```bash
# Avec nom personnalisé
cat secrets.txt | sudo ./install.sh --worker-name "prod-1"

# Sans installation auto des dépendances
cat secrets.txt | sudo ./install.sh --no-auto-deps
```

## Maintenance

```bash
sudo ./manage.sh
```

Menu interactif : lister, renommer, upgrade, supprimer les workers.

### Worker existant : jobs Docker qui plantent (PREFECT_HOME)

Si les flows en conteneur Docker échouent avec « Failed to create the Prefect home directory » ou « Unable to authenticate to the event stream », le worker ne doit pas transmettre son `PREFECT_HOME` au conteneur. À faire sur la VM :

1. Retirer `PREFECT_HOME` du fichier env du worker :
   ```bash
   sudo sed -i '/^PREFECT_HOME=/d' /etc/prefect-worker-<nom>.env
   ```
2. L’ajouter uniquement dans le unit systemd (remplacer `<nom>` et le chemin si besoin) :
   ```bash
   sudo sed -i '/EnvironmentFile=/a Environment=PREFECT_HOME=/opt/prefect/<nom>/.prefect' /etc/systemd/system/prefect-worker-<nom>.service
   ```
3. Recharger et redémarrer :
   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart prefect-worker-<nom>
   ```

Les nouvelles installations font déjà cette séparation automatiquement.

## Commandes utiles

```bash
journalctl -u prefect-worker-<nom> -f     # Logs
systemctl status prefect-worker-<nom>      # Status
sudo systemctl restart prefect-worker-<nom> # Redémarrer
```

## Sécurité

- Secrets via stdin (non visibles dans `ps`)
- Fichiers env en mode 600 (root only)
- Hardening systemd complet

## Documentation supplémentaire

- [Configuration Work Pool centralisée](docs/work-pool-default-env-recommendation.md) - Guide pour centraliser les variables d'environnement dans le Work Pool

## Prérequis

- Linux + systemd
- Python 3.8+
- Accès root

## Licence

MIT
