# ADR 0001: Sólo lectura por construcción, no por convención

**Estado.** Aceptado, 2026-09.

## Contexto

El objetivo declarado es responder tres preguntas sobre un parque de Jenkins: qué jobs
existen y cómo están configurados, qué commit alimenta a cada uno, y en qué difieren de lo
declarado. Ninguna de las tres necesita escribir.

El camino de escritura, en cambio, tiene tres dificultades reales:

| El comportamiento | La implementación obvia | Qué destruye |
| --- | --- | --- |
| `POST /job/<ruta>/config.xml` reemplaza el documento completo | Enviar el XML que la declaración describe | Todo lo que la declaración no menciona: un parámetro, un trigger, la sección de un plugin |
| El credential store nunca devuelve un secreto en un `GET` | Leer, modificar, escribir | La credencial, reemplazada por nada, mientras la API reporta éxito |
| El workflow de Jira ya lo escriben los propios `Jenkinsfile` | Comentar y transicionar desde acá también | Nada visible: produce transiciones dobles que después nadie puede atribuir |

## Decisión

**No existe camino de código que escriba.** No un `apply` deshabilitado, no un
`-ConfirmApply` que falta, no una guarda: la ausencia de la función.

Concretamente:

- `JenkinsAsCode.Http` no tiene parámetro `-Method`. `Invoke-ReadOnlyRequest` manda `GET`
  y nada más.
- `Jenkins.Rest` y `Jira.Rest` no exponen ninguna función que envíe otra cosa.
- Ningún `ValidateSet` de ningún punto de entrada contiene `apply`, `reconcile`, `rename`,
  `delete` ni `remove`.
- Ningún punto de entrada declara un parámetro de confirmación.
- `Scm.Git` no tiene camino de `checkout`, `reset`, `pull`, `merge`, `commit` ni `push`.

Y está verificado, no sólo escrito: `tests/automations/Automations.Tests.ps1` hace grep
sobre el código fuente exigiendo la **ausencia** de cada uno de esos, y exige que
`Invoke-WebRequest` aparezca en **un solo archivo**.

Levantar la restricción es un ADR, no un commit.

## Por qué la ausencia y no una guarda

Es el mismo razonamiento que llevó al repositorio del que viene este diseño a no tener
código para renombrar una Service Connection: la API no puede hacerlo sin destruir la
credencial, el portal sí, y por lo tanto no existe la función. Si no hay nada que agarrar,
nadie lo agarra por accidente a las dos de la mañana.

Una guarda es una decisión que alguien puede revertir con un `-Force` en un momento de
apuro. Una función que no existe hay que escribirla, y escribirla es visible en un diff.

## Consecuencias

**Bueno.** El radio de impacto de una corrida es un archivo bajo `artifacts/`. No hay
rollback que diseñar porque no hay nada que revertir. El repositorio se puede correr
contra producción el primer día sin una conversación previa sobre riesgo.

**Malo.** Lo que el plan reporta como `pending` lo arregla una persona en la UI, y nada
garantiza que lo haga. La herramienta detecta la deriva y no la corrige. Para el problema
que hay hoy —que nadie puede *ver* la configuración— eso es exactamente el alcance útil,
pero no es el alcance final.

**Neutro.** El vocabulario de estados se mantiene igual al del repositorio hermano aunque
`pending` signifique algo distinto. Ver [command-model.md](../reference/command-model.md),
sección 2.

## Qué haría falta para levantarlo

Para escribir un `config.xml` con seguridad: leer el documento vivo, modificar sólo los
nodos declarados, escribir el resultado, y **no** construirlo desde una plantilla. Más
manejo de crumb CSRF, el permiso `Job/Configure`, y un plan de rollback que diga qué hacer
cuando un `POST` ya reemplazó el documento. Es un trabajo distinto con un perfil de riesgo
distinto, y merece su propio ADR.
