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

## Prérequis

- Linux + systemd
- Python 3.8+
- Accès root

## Licence

MIT
