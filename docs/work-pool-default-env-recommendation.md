# Work Pool – Configuration centralisée (huco_etl)

Ce document décrit la configuration du Work Pool `huco_etl` qui centralise toutes les
variables d'environnement PROD, évitant ainsi la duplication dans `prefect.yaml`.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WORK POOL "huco_etl"                                │
│                                                                             │
│  Job Template (defaults centralisés):                                       │
│  ├── image: ghcr.io/humans-connexion/lxboard-etl:latest                    │
│  ├── image_pull_policy: Always                                             │
│  ├── network_mode: host                                                    │
│  └── env:                                                                  │
│      ├── ENV_TYPE: PROD                                                    │
│      ├── PYTHONUNBUFFERED: 1                                               │
│      ├── PREFECT_HOME: /app/.prefect                                       │
│      ├── PREFECT_API_URL: https://api.prefect.cloud/...                    │
│      ├── PREFECT_API_KEY: {{ prefect.blocks.secret.prefect-api-key }}      │
│      └── POSTGRES_*: {{ prefect.blocks.json.lxboard-bdd-prod.value.* }}    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
        ┌───────────────────┐           ┌───────────────────┐
        │   Déploiement A   │           │   Déploiement B   │
        │   (minimal)       │           │   (avec volumes)  │
        │                   │           │                   │
        │ job_variables:    │           │ job_variables:    │
        │   registry_creds  │           │   registry_creds  │
        │                   │           │   volumes: [...]  │
        └───────────────────┘           └───────────────────┘
```

## Variables héritées du Work Pool

Ces variables sont définies dans le Work Pool et **ne doivent plus être répétées** dans `prefect.yaml` :

| Variable | Source | Description |
|----------|--------|-------------|
| `ENV_TYPE` | Valeur fixe | `PROD` |
| `PYTHONUNBUFFERED` | Valeur fixe | `1` (logs temps réel) |
| `PREFECT_HOME` | Valeur fixe | `/app/.prefect` |
| `PREFECT_API_URL` | Valeur fixe | URL workspace Prefect Cloud |
| `PREFECT_API_KEY` | Bloc Secret | `{{ prefect.blocks.secret.prefect-api-key }}` |
| `POSTGRES_HOST` | Bloc JSON | `{{ prefect.blocks.json.lxboard-bdd-prod.value.host }}` |
| `POSTGRES_PORT` | Bloc JSON | `{{ prefect.blocks.json.lxboard-bdd-prod.value.port }}` |
| `POSTGRES_DB` | Bloc JSON | `{{ prefect.blocks.json.lxboard-bdd-prod.value.database }}` |
| `POSTGRES_USER` | Bloc JSON | `{{ prefect.blocks.json.lxboard-bdd-prod.value.user }}` |
| `POSTGRES_PASSWORD` | Bloc JSON | `{{ prefect.blocks.json.lxboard-bdd-prod.value.password }}` |

## Autres defaults (non-env)

| Variable | Valeur | Description |
|----------|--------|-------------|
| `image` | `ghcr.io/humans-connexion/lxboard-etl:latest` | Image Docker |
| `image_pull_policy` | `Always` | Toujours pull la dernière image |
| `network_mode` | `host` | Accès réseau host (BDD on-premise) |
| `stream_output` | `true` | Logs en temps réel |

## Résultat dans prefect.yaml

Chaque déploiement devient minimal :

```yaml
# Déploiement simple (hérite de tout)
work_pool:
  name: huco_etl
  work_queue_name: default
  job_variables:
    registry_credentials: "{{ prefect.blocks.docker-registry-credentials.lxboard-image }}"

# Déploiement avec volumes (dbt/docker-in-docker)
work_pool:
  name: huco_etl
  work_queue_name: default
  job_variables:
    registry_credentials: "{{ prefect.blocks.docker-registry-credentials.lxboard-image }}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

## Blocs Prefect requis

| Bloc | Type | Description |
|------|------|-------------|
| `prefect-api-key` | Secret | Clé API Prefect Cloud (pour event stream dans le conteneur) |
| `lxboard-bdd-prod` | JSON | Credentials PostgreSQL PROD (`host`, `port`, `database`, `user`, `password`) |
| `lxboard-image` | Docker Registry Credentials | Credentials GHCR pour pull l'image |

## Mise à jour du Work Pool

Pour modifier le Job Template dans Prefect Cloud :

1. Aller sur **Work Pools** > `huco_etl` > **Edit**
2. Cliquer sur **Advanced** > **Job Template**
3. Remplacer le JSON complet (voir ci-dessous)
4. **Save**

### Job Template complet

```json
{
  "variables": {
    "type": "object",
    "properties": {
      "env": {
        "type": "object",
        "title": "Environment Variables",
        "default": {
          "ENV_TYPE": "PROD",
          "PYTHONUNBUFFERED": "1",
          "PREFECT_HOME": "/app/.prefect",
          "PREFECT_API_URL": "https://api.prefect.cloud/api/accounts/1e95f180-fd2c-4b7e-a484-992b0c53919e/workspaces/e7489d6d-7456-422f-aa05-38c3b72f770f",
          "PREFECT_API_KEY": "{{ prefect.blocks.secret.prefect-api-key }}",
          "POSTGRES_HOST": "{{ prefect.blocks.json.lxboard-bdd-prod.value.host }}",
          "POSTGRES_PORT": "{{ prefect.blocks.json.lxboard-bdd-prod.value.port }}",
          "POSTGRES_DB": "{{ prefect.blocks.json.lxboard-bdd-prod.value.database }}",
          "POSTGRES_USER": "{{ prefect.blocks.json.lxboard-bdd-prod.value.user }}",
          "POSTGRES_PASSWORD": "{{ prefect.blocks.json.lxboard-bdd-prod.value.password }}"
        },
        "description": "Environment variables to set when starting a flow run.",
        "additionalProperties": {
          "anyOf": [{ "type": "string" }, { "type": "null" }]
        }
      },
      "name": {
        "anyOf": [{ "type": "string" }, { "type": "null" }],
        "title": "Name",
        "description": "Name given to infrastructure created by the worker using this job configuration."
      },
      "image": {
        "type": "string",
        "title": "Image",
        "default": "ghcr.io/humans-connexion/lxboard-etl:latest",
        "examples": ["docker.io/prefecthq/prefect:3-latest"],
        "description": "The image reference of a container image to use for created jobs."
      },
      "labels": {
        "type": "object",
        "title": "Labels",
        "additionalProperties": { "type": "string" }
      },
      "command": {
        "anyOf": [{ "type": "string" }, { "type": "null" }],
        "title": "Command"
      },
      "volumes": {
        "type": "array",
        "items": { "type": "string" },
        "title": "Volumes"
      },
      "networks": {
        "type": "array",
        "items": { "type": "string" },
        "title": "Networks"
      },
      "mem_limit": {
        "anyOf": [{ "type": "string" }, { "type": "null" }],
        "title": "Memory Limit"
      },
      "privileged": {
        "type": "boolean",
        "title": "Privileged",
        "default": false
      },
      "auto_remove": {
        "type": "boolean",
        "title": "Auto Remove",
        "default": false
      },
      "network_mode": {
        "anyOf": [{ "type": "string" }, { "type": "null" }],
        "title": "Network Mode",
        "default": "host"
      },
      "memswap_limit": {
        "anyOf": [{ "type": "string" }, { "type": "null" }],
        "title": "Memory Swap Limit"
      },
      "stream_output": {
        "type": "boolean",
        "title": "Stream Output",
        "default": true
      },
      "image_pull_policy": {
        "anyOf": [
          { "enum": ["IfNotPresent", "Always", "Never"], "type": "string" },
          { "type": "null" }
        ],
        "title": "Image Pull Policy",
        "default": "Always"
      },
      "registry_credentials": {
        "anyOf": [
          { "$ref": "#/definitions/DockerRegistryCredentials" },
          { "type": "null" }
        ]
      },
      "container_create_kwargs": {
        "anyOf": [
          { "type": "object", "additionalProperties": true },
          { "type": "null" }
        ],
        "title": "Container Configuration"
      }
    },
    "definitions": {
      "DockerRegistryCredentials": {
        "type": "object",
        "title": "DockerRegistryCredentials",
        "required": ["username", "password", "registry_url"],
        "properties": {
          "reauth": { "type": "boolean", "default": true },
          "password": { "type": "string", "format": "password", "writeOnly": true },
          "username": { "type": "string" },
          "registry_url": { "type": "string", "examples": ["index.docker.io"] }
        },
        "secret_fields": ["password"],
        "block_type_slug": "docker-registry-credentials",
        "additionalProperties": true,
        "block_schema_references": {}
      }
    }
  },
  "job_configuration": {
    "env": "{{ env }}",
    "name": "{{ name }}",
    "image": "{{ image }}",
    "labels": "{{ labels }}",
    "command": "{{ command }}",
    "volumes": "{{ volumes }}",
    "networks": "{{ networks }}",
    "mem_limit": "{{ mem_limit }}",
    "privileged": "{{ privileged }}",
    "auto_remove": "{{ auto_remove }}",
    "network_mode": "{{ network_mode }}",
    "memswap_limit": "{{ memswap_limit }}",
    "stream_output": "{{ stream_output }}",
    "image_pull_policy": "{{ image_pull_policy }}",
    "registry_credentials": "{{ registry_credentials }}",
    "container_create_kwargs": "{{ container_create_kwargs }}"
  }
}
```
