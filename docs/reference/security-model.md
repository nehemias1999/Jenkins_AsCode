# Modelo de seguridad

**Propósito.** Decir dónde viven las credenciales, qué nunca se escribe, y qué hace
cumplir cada regla.

**Alcance.** Manejo de credenciales y datos sensibles.

**Documentos relacionados**

- [ADR 0001](../adr/0001-read-only-by-construction.md) — por qué no hay escritura
- [scope-and-limits.md](../overview/scope-and-limits.md) — los secretos ya expuestos, fuera de alcance

## 1. Un principio

**La configuración declara el nombre de un secreto. Nunca contiene uno.**

```json
{ "baseUrlEnv": "JENKINS_URL", "tokenEnv": "JENKINS_API_TOKEN" }
```

No la URL. No el token. Los **nombres** de las variables de entorno que los llevan.

Todo lo demás se sigue de ahí. La configuración se puede commitear, revisar como diff y
compartir, porque no hay nada adentro que filtrar. Los valores viven en `.env` en una
estación o en variables secretas de un pipeline, y el camino de código es idéntico en los
dos casos: un camino que razonar en lugar de dos.

## 2. Dónde viven los valores

| Valor | Vive en | Llega al código como |
| --- | --- | --- |
| URL del controller | `.env` | `JENKINS_URL` |
| Usuario del controller | `.env` | `JENKINS_USER` |
| Token de API de Jenkins | `.env` | `JENKINS_API_TOKEN` |
| URL de Jira | `.env` | `JIRA_BASE_URL` |
| Email de la cuenta de Jira | `.env` | `JIRA_EMAIL` |
| Token de API de Jira | `.env` | `JIRA_API_TOKEN` |

Ninguno de esos archivos está versionado. `.gitignore` excluye `.env*` salvo
`.env.example`, más `.local/`, `artifacts/`, y cada archivo de configuración activo creado
al renombrar una plantilla.

Un token, no una contraseña: un token se revoca por su cuenta, no habilita una sesión
interactiva, y Jenkins exime del crumb CSRF a las peticiones autenticadas con token.

## 3. Tres cosas que este repositorio se niega a leer o a escribir

**El default de un parámetro Password.** Está cifrado de forma **reversible** con la clave
del controller, no hasheado. Es el único campo de una definición de job que el parser se
niega a leer: se reportan el nombre y el tipo, y el valor se reemplaza por un marcador. Un
reporte es justamente el artefacto que termina pegado en un ticket.

**El default de cualquier parámetro, en el snapshot.** El snapshot que `job-inventory`
escribe lleva nombre y tipo, nunca valor. Un default no secreto es inocuo, pero
distinguirlo de uno secreto con suficiente confiabilidad no vale el riesgo en un archivo
que se comparte.

**El contenido de un `Jenkinsfile`.** `pipeline-drift` compara archivos y reporta
**fingerprints SHA-256**, no texto. Esos archivos suelen contener credenciales en
claro; un reporte que las transcribiera propagaría el problema que existe para detectar.

## 4. Lo que no se sigue a otro host

`MaximumRedirection = 0`. Si el cliente siguiera un 30x, mandaría el header
`Authorization` al host que indique el `Location`. La causa habitual de un redirect acá es
una URL base equivocada, así que se reporta como el problema de configuración que es, en
lugar de exponer el token averiguándolo.

Tampoco se desactiva nunca la verificación TLS. No hay `-SkipCertificateCheck` ni
manipulación de la validación de certificados en ningún lado.

## 5. La puerta mecánica

`scripts/Test-NoSensitiveData.ps1` escanea el repositorio y falla ante tokens de Atlassian,
PAT de GitHub, claves de acceso de AWS, claves privadas, claves públicas SSH, JWT, pares
clave-valor que parecen una contraseña, direcciones IP privadas, hostnames internos, rutas
UNC, rutas de perfil de usuario y direcciones de correo fuera de los dominios reservados de
ejemplo.

Corre como parte de `scripts/Invoke-Tests.ps1`, que es el mismo comando que corre la
integración continua, así que "pasó local" y "pasó en CI" significan lo mismo.

Si marca algo que se cree falso positivo, se acota la expresión de permitidos de esa regla.
**Nunca** se ensancha la regla para que el hallazgo desaparezca.

## 6. Los fixtures son inventados

Todo fixture y toda plantilla usan hosts de ejemplo. Un fixture que tomara prestado un
nombre de host, una ruta de job o una credencial real convertiría la suite de tests en otro
lugar del que se filtran datos, y los archivos de test son el último lugar donde alguien
mira.

Un test del contrato lo verifica: toda URL en una plantilla tiene que apuntar a un dominio
`example.com`, `example.org` o `example.net`.
