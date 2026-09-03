# Índice de documentación

**Propósito.** Llevar a quien lee al único documento que responde su pregunta.

**Alcance.** Todos los documentos del repositorio. Un documento no indexado se trata como
incompleto, y la suite de tests lo hace cumplir.

**Audiencia.** Todos. Empezar acá.

## 1. Leer según la necesidad

| Necesito... | Empezar por | Después |
| --- | --- | --- |
| Entender para qué sirve esto | [problem-statement.md](overview/problem-statement.md) | [capabilities.md](overview/capabilities.md) |
| Saber exactamente qué puede y qué no | [capabilities.md](overview/capabilities.md) | [scope-and-limits.md](overview/scope-and-limits.md) |
| Correrlo por primera vez | [getting-started.md](guides/getting-started.md) | [command-model.md](reference/command-model.md) |
| Averiguar por qué algo falló | [troubleshooting.md](guides/troubleshooting.md) | [jenkins-notes.md](reference/jenkins-notes.md) |
| Entender un error raro de la API de Jenkins | [jenkins-notes.md](reference/jenkins-notes.md) | |
| Ídem, de Jira | [jira-notes.md](reference/jira-notes.md) | |
| Interpretar un plan | [command-model.md](reference/command-model.md) | |
| Cambiar el código | [architecture.md](reference/architecture.md) | [automation-contract.md](reference/automation-contract.md) |
| Agregar una automatización | [automation-contract.md](reference/automation-contract.md) | [architecture.md](reference/architecture.md) |
| Saber cómo se manejan las credenciales | [security-model.md](reference/security-model.md) | [scope-and-limits.md](overview/scope-and-limits.md) |
| Juzgar cuánto vale el build verde | [testing-strategy.md](process/testing-strategy.md) | |
| Entender por qué no escribe nada | [0001-read-only-by-construction.md](adr/0001-read-only-by-construction.md) | [scope-and-limits.md](overview/scope-and-limits.md) |

## 2. Guías de los módulos

Cada automatización trae su guía junto al código, que es donde se busca:

| Módulo | Guía |
| --- | --- |
| `job-inventory` | [../automations/job-inventory/README.md](../automations/job-inventory/README.md) |
| `pipeline-drift` | [../automations/pipeline-drift/README.md](../automations/pipeline-drift/README.md) |
| `jira-inventory` | [../automations/jira-inventory/README.md](../automations/jira-inventory/README.md) |

## 3. Todo el índice

### Visión general

- [problem-statement.md](overview/problem-statement.md) — qué pregunta no se puede responder hoy
- [capabilities.md](overview/capabilities.md) — cada capacidad, dónde vive y cómo se invoca
- [scope-and-limits.md](overview/scope-and-limits.md) — qué **no** hace, y por qué cada hueco es una decisión

### Referencia

- [architecture.md](reference/architecture.md) — las capas y la regla de dependencias
- [command-model.md](reference/command-model.md) — cada verbo, estado y acción
- [automation-contract.md](reference/automation-contract.md) — las seis cosas que todo módulo debe traer
- [security-model.md](reference/security-model.md) — dónde viven las credenciales y qué nunca se escribe
- [jenkins-notes.md](reference/jenkins-notes.md) — dieciséis comportamientos de la API de Jenkins, con su síntoma
- [jira-notes.md](reference/jira-notes.md) — ídem, para Jira

### Guías

- [getting-started.md](guides/getting-started.md) — de cero a la primera lectura
- [troubleshooting.md](guides/troubleshooting.md) — el síntoma primero, la causa después

### Proceso

- [testing-strategy.md](process/testing-strategy.md) — qué se prueba, qué no, y qué encontró la suite

### Decisiones de arquitectura

- [0001-read-only-by-construction.md](adr/0001-read-only-by-construction.md) — sólo lectura por ausencia de código, no por convención
- [0002-git-cli-instead-of-provider-apis.md](adr/0002-git-cli-instead-of-provider-apis.md) — leer el SCM por `git`, no por la API de cada proveedor
- [0003-shared-http-layer.md](adr/0003-shared-http-layer.md) — el HTTP genérico en la capa base

## 4. Reglas de esta documentación

Todo documento abre con **Propósito**, **Alcance** y, cuando ayuda, **Audiencia** y
**Documentos relacionados**. Sirve para que alguien decida en dos líneas si es el documento
que necesita.

Un documento que no está enlazado desde acá se considera incompleto: la suite de tests
falla. Un documento que nadie puede alcanzar desde el índice es un documento que nadie lee,
y se separa del código en silencio.

Las notas de comportamiento dicen **el síntoma**, no sólo la causa, porque un error se busca
por el síntoma.
