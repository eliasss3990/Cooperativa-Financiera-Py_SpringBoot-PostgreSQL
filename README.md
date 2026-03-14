# Cooperativa Financiera PY — Backend

Spring Boot 4 + PostgreSQL 16

---

## Entornos

El proyecto tiene tres entornos. Cada uno cumple un rol distinto y no deben mezclarse.

| Entorno     | Quién lo usa            | Cuándo                       | Archivo env | Docker Compose           | Puerto app |
|-------------|-------------------------|------------------------------|-------------|--------------------------|------------|
| **Dev**     | Desarrolladores (local) | Desarrollo diario            | `.env.dev`  | `docker-compose.dev.yml` | 8801       |
| **Staging** | Desarrolladores / QA    | Validar antes de producción  | `.env`      | `docker-compose.yml`     | 8800       |
| **Test**    | GitHub Actions          | Automáticamente en cada push | —           | —                        | —          |

### Dev
Se usa en el día a día mientras se escribe código. Tiene logging verbose, muestra las queries SQL en consola
y expone el puerto de debug `5005` para poder conectar el IDE y hacer breakpoints.
Solo lo levantan los desarrolladores en sus máquinas locales.

### Staging
Simula cómo va a correr la app en producción. Se usa para validar que todo funciona correctamente
antes de "deployar de verdad": que Flyway aplica las migraciones, que los endpoints responden bien,
que los logs no tienen ruido innecesario. No tiene debug port ni logging verbose.
Se levanta cuando una PR a `master` es mergeada y se quiere verificar el build final.

### Test
Lo usa exclusivamente el pipeline de GitHub Actions durante el job de tests.
No se levanta manualmente. Flyway está desactivado y el esquema se crea y destruye automáticamente
en cada ejecución para garantizar aislamiento entre runs.

---

## Setup — Desarrollo (dev)

```bash
# 1. Copiar el archivo de entorno dev
cp .env.dev.example .env.dev

# 2. Levantar la base de datos + backend (con debug port 5005)
docker compose -f docker-compose.dev.yml --env-file .env.dev up -d
```

---

## Setup — Staging (simulación de producción)

```bash
# 1. Copiar el archivo de entorno staging
cp .env.example .env
# Editar .env con las credenciales reales

# 2. Levantar todo
docker compose up -d
```

---

## CI/CD — GitHub Actions

El pipeline se dispara automáticamente al hacer **push** a:
- `feature/eliasgonzalez`
- `feature/enzodominguez`

### Jobs

```
test ──────────────┐
                   ├──► sonarcloud ──► create-pr
code-quality ──────┘
```

1. **test**: Levanta una base PostgreSQL temporal y ejecuta todos los tests del proyecto.
2. **code-quality**: Corre PMD y Checkstyle para verificar calidad y estilo del código. No necesita base de datos y corre en paralelo con `test`.
3. **sonarcloud**: Analiza cobertura y calidad con SonarCloud. Depende de que `test` y `code-quality` pasen.
4. **create-pr**: Si todos los jobs anteriores pasan, crea automáticamente una PR hacia `master`.

Si cualquier job falla, los siguientes no se ejecutan y la PR no se crea.

---

## PMD y Checkstyle

Son dos herramientas de análisis estático que se ejecutan **antes** de SonarCloud. No necesitan correr los tests
ni conectarse a ninguna base de datos — solo analizan el código fuente directamente.

### Checkstyle

Verifica que el código respete las **convenciones de estilo** definidas en `config/checkstyle/checkstyle.xml`.
No analiza si el código funciona, solo si está escrito de forma consistente. Algunas cosas que revisa:

- Sin imports con wildcard (`import java.util.*` está prohibido — hay que importar clase por clase).
- Sin imports sin usar.
- Nombres de clases en PascalCase, métodos y variables en camelCase, constantes en UPPER_SNAKE_CASE.
- Siempre usar llaves en `if`, `for`, `while` — aunque sea una sola línea.
- No usar `System.out.println()` — hay que usar el logger (SLF4J).
- Máximo 120 caracteres por línea.
- Sin tabs — solo espacios.

Si Checkstyle falla, el error muestra exactamente en qué línea y archivo está la violación.

### PMD

Analiza el código en busca de **bugs potenciales, malas prácticas y problemas de performance**.
A diferencia de Checkstyle, PMD sí entiende la lógica del código. Algunas cosas que detecta:

- Variables o imports declarados pero nunca usados.
- Bloques `catch` que ignoran la excepción sin ningún comentario.
- Concatenación de Strings dentro de un loop (usar `StringBuilder` en cambio).
- Comparar objetos con `==` en lugar de `.equals()`.
- Recursos (conexiones, streams) que pueden no cerrarse correctamente.
- Uso de algoritmos de hashing inseguros (MD5, SHA-1).

Las reglas están configuradas en `config/pmd/ruleset.xml`. Algunas reglas demasiado estrictas
para Spring Boot o Lombok están desactivadas (documentadas con comentarios en el archivo).

### Cómo correrlos localmente

```bash
# Compilar primero (PMD necesita las clases compiladas)
mvn compile -B

# Checkstyle
mvn checkstyle:check -B

# PMD
mvn pmd:check -B

# Ambos juntos
mvn compile checkstyle:check pmd:check -B
```

Si hay violaciones, el build falla y se listan los problemas en la consola con archivo y número de línea.

---

## SonarCloud

SonarCloud es una herramienta de análisis estático de código. Analiza el código fuente en busca de:

- **Bugs**: código que puede producir un comportamiento incorrecto en runtime.
- **Vulnerabilidades**: código que puede representar un riesgo de seguridad.
- **Code smells**: código que funciona pero es difícil de mantener o entender.
- **Cobertura de tests**: qué porcentaje del código está cubierto por tests unitarios.
- **Código duplicado**: bloques de código repetidos que deberían estar abstraídos.

Cada análisis produce un resultado que puede ser **passed** o **failed** según las reglas del proyecto
(llamadas *Quality Gate*). Si el Quality Gate falla, significa que el código introducido no cumple
con los estándares mínimos de calidad definidos.

### Cómo hacer que el análisis pase

Para que el Quality Gate pase, el código que se agrega en cada PR debe cumplir:

- **No introducir bugs ni vulnerabilidades** nuevas. SonarCloud analiza el código y detecta patrones
  problemáticos, como nulls sin verificar, recursos no cerrados, comparaciones incorrectas, etc.
- **Mantener o mejorar la cobertura de tests**. Por defecto SonarCloud pide al menos un 80% de
  cobertura sobre el código nuevo. Si se agrega lógica sin tests, el análisis puede fallar.
- **No introducir code smells graves**. Métodos demasiado largos, clases con demasiadas
  responsabilidades, variables sin usar, complejidad ciclomática alta, etc.

La forma más simple de no tener sorpresas: **escribir tests para toda la lógica de negocio que se agregue**.

### Ver los resultados

Los resultados del análisis aparecen directamente en la PR de GitHub como un comentario automático.

---

## Perfiles Spring

| Perfil | Activación                    | Comportamiento                                 |
|--------|-------------------------------|------------------------------------------------|
| `dev`  | `SPRING_PROFILES_ACTIVE=dev`  | Show SQL, logging DEBUG, Flyway activo         |
| `prod` | `SPRING_PROFILES_ACTIVE=prod` | Sin show SQL, logging INFO/WARN, Flyway activo |
| `test` | `SPRING_PROFILES_ACTIVE=test` | DDL create-drop, Flyway desactivado            |

---

## Makefile

Atajos para los comandos más usados. Corré `make` sin argumentos para ver todos.

```bash
# Dev
make up              # levantar DB + backend
make up-build        # levantar reconstruyendo la imagen
make down            # bajar contenedores
make down-v          # bajar y eliminar volúmenes
make restart         # reiniciar solo el backend
make logs            # logs del backend en tiempo real
make logs-all        # logs de todos los servicios
make shell           # shell dentro del contenedor del backend

# Base de datos
make db-connect      # abrir psql en el contenedor de la DB
make snapshot        # guardar snapshot de la DB
make restore         # restaurar snapshot de la DB

# Calidad
make validate        # compile + Checkstyle + PMD + tests
make validate-fast   # compile + Checkstyle + PMD (sin tests)
make clean           # eliminar target/

# Entorno
make reset           # resetear entorno dev desde cero (rebuild incluido)
make reset-db        # resetear solo la DB
make reset-fast      # resetear sin rebuild de imagen
```

---

## Scripts

Scripts de utilidad en `scripts/`. Cada uno tiene documentación interna en el archivo, o corré `bash scripts/<nombre>.sh --help` para verla.

| Script              | Descripción                                                                                                                                                                         |
|---------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `reset-dev.sh`      | Reseteo completo del entorno dev: baja contenedores, elimina volúmenes, reconstruye la imagen y vuelve a levantar todo. Flyway corre automáticamente al reiniciar.                  |
| `db-snapshot.sh`    | Guarda y restaura snapshots de la DB dev como archivos SQL con timestamp. Útil antes de aplicar migraciones destructivas o para compartir un estado de datos entre desarrolladores. |
| `validate-local.sh` | Corre los mismos checks que el CI (compile → Checkstyle → PMD → tests) antes de hacer push. Si pasa acá, pasa en GitHub Actions.                                                    |

```bash
# Resetear entorno dev desde cero
bash scripts/reset-dev.sh

# Guardar estado de la DB antes de una migración riesgosa
bash scripts/db-snapshot.sh save "antes-migracion-v2"

# Verificar que todo pasa antes de hacer push
bash scripts/validate-local.sh
```

---

## Comandos útiles

```bash
# Ver logs del backend
docker compose -f docker-compose.dev.yml logs -f backend

# Detener y eliminar volúmenes (dev)
docker compose -f docker-compose.dev.yml down -v

# Ejecutar tests localmente
mvn test -DSPRING_PROFILES_ACTIVE=test

# Análisis SonarCloud local (requiere SONAR_TOKEN en el entorno)
mvn verify sonar:sonar \
  -Dsonar.projectKey=TU_PROJECT_KEY \
  -Dsonar.organization=TU_ORGANIZATION
```

