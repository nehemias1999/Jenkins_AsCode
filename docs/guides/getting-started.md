# Primeros pasos

**Propósito.** Llevar una estación de cero a una configuración validada y una primera
lectura contra el controller.

**Alcance.** Prerrequisitos, los tokens, los archivos locales.

**Documentos relacionados**

- [troubleshooting.md](troubleshooting.md) — cuando un paso de acá no hace lo que dice
- [../reference/security-model.md](../reference/security-model.md) — por qué los tokens se manejan así

## 1. Prerrequisitos

| Requisito | Notas |
| --- | --- |
| Windows PowerShell 5.1 o PowerShell 7 | Nada más. Sin módulos que instalar, sin SDK, sin gestor de paquetes. Es deliberado: una herramienta que observa una plataforma tiene que correr en una estación restringida y en un agente de build sin preparar ninguno de los dos. |
| Git | Para clonar este repositorio, y para que `pipeline-drift` lea los remotos. |
| Una cuenta con acceso al controller | El token no otorga ningún permiso que la cuenta no tenga ya. |
| Pester 5 o superior y PSScriptAnalyzer | **Sólo** para correr la suite de tests. Ninguna automatización los necesita. |

En PowerShell 5.1 la configuración se valida con un validador de schema reducido; en
PowerShell 7 corre el completo. Los dos se hacen cumplir, y el resultado nombra cuál corrió.

## 2. Preparar la estación

```powershell
git clone https://github.com/nehemias1999/Jenkins_AsCode.git
cd Jenkins_AsCode
.\scripts\bootstrap.ps1
```

`bootstrap.ps1` verifica las versiones, carga los módulos de la fundación, crea `.local/` y
`artifacts/`, y crea `.env` a partir de `.env.example`. No sobrescribe un `.env` existente.

## 3. Empezar por lo que no necesita credenciales

```powershell
.\automations\job-inventory\Invoke-JobInventory.ps1    -Command validate
.\automations\pipeline-drift\Invoke-PipelineDrift.ps1  -Command validate
.\automations\jira-inventory\Invoke-JiraInventory.ps1  -Command validate
```

`validate` es offline: sin red, sin token. Prueba que la declaración es sana y que el
repositorio está bien instalado. Si estos tres pasan, todo lo que falta es acceso.

Sin declaración activa, `validate` usa la plantilla versionada y **lo dice**. Una corrida
nunca verifica la plantilla en silencio mientras quien la corre cree que verificó su propia
declaración.

## 4. El token de Jenkins

**Perfil > Configure > API Token > Add new Token.** No la contraseña de la cuenta: un token
se revoca por su cuenta y no habilita una sesión interactiva.

| Permiso | Para qué |
| --- | --- |
| `Overall/Read` | Alcanzar el controller. |
| `Job/Read` | Listar los hijos de una carpeta. |
| **`Job/ExtendedRead`** | Leer `config.xml`. **Sin esto no funciona nada útil.** Con `Job/Read` solo, `/api/json` responde y `config.xml` da 403 — un inventario que lista cuarenta jobs y falla en el primero es casi siempre esto. |

En `.env`:

```text
JENKINS_URL=https://jenkins.example.com
JENKINS_USER=tu-usuario
JENKINS_API_TOKEN=...
```

La URL sin barra final, con esquema, sin query y sin fragmento. `Assert-HttpBaseUrl`
rechaza las cuatro cosas nombrando la variable a corregir.

## 5. El token de Jira

De **id.atlassian.com > Security > API tokens**. Se empareja con el **email** de la cuenta,
no con un nombre de usuario: Jira Cloud rechaza un nombre de usuario con un 401 que se lee
como token equivocado.

Permiso necesario: `Browse Projects` sobre cada proyecto en alcance.

```text
JIRA_BASE_URL=https://tu-tenant.atlassian.net
JIRA_EMAIL=persona@example.com
JIRA_API_TOKEN=...
```

## 6. La primera lectura

```powershell
.\automations\job-inventory\Invoke-JobInventory.ps1 -Command inventory
```

Recorre las carpetas declaradas y escribe un snapshot bajo `artifacts/reports/`. Ese
snapshot tiene todo lo necesario para escribir la declaración: ruta, tipo, estado, URL del
repositorio, Branch Specifier, ruta del script, parámetros y triggers de cada job.

## 7. Derivar la declaración, y probar que coincide

```text
config/jobs.example.json  ->  config/jobs.json
```

Se completa `jobs.json` con lo que el snapshot encontró — **no a mano desde la UI**. Y
después:

```powershell
.\automations\job-inventory\Invoke-JobInventory.ps1 -Command plan
```

**Tiene que dar cero `pending`.** Ese cero es la prueba de que el inventario y la
comparación coinciden. Sin él, ningún hallazgo posterior es creíble.

## 8. Y después

```powershell
.\automations\pipeline-drift\Invoke-PipelineDrift.ps1 -Command plan
```

Responde qué commit alimenta realmente a cada job, y si la copia local es ese código.
Necesita `pipelines.json` con el mapeo de job a copia de trabajo.
