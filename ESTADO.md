# ESTADO.md — Estado de la implementación

Documento vivo. Se actualiza al terminar cada paso, no al final de la sesión. El plan
completo de cada fase vive en `ILoveVigoRoutes-HANDOFF.md`; esto es solo "dónde estamos".

---

## Resumen

| Fase | Estado |
|---|---|
| Fase 0 — Verificación y cimientos | ✅ Hecha |
| Fase 1 — Paradas y tiempo real | ✅ Hecha |
| Fase 2 — Ferry de la ría | ⬜ No empezada |
| **Fase 3 — Planificador de rutas (RAPTOR)** | 🔶 **En curso: 3/11 pasos** |
| Fase 4 — Pulido y comodidades | ⬜ No empezada |

---

## Fase 3 — Planificador de rutas

Plan detallado (arquitectura, ficheros, secuencia completa de 11 pasos) en
`~/.claude/plans/actua-como-un-planificador-immutable-parnas.md`. Resumen de decisiones:
solo bus (ferry fuera hasta que exista Fase 2), solo consultas hacia delante, tiempo real
fuera del motor, RAPTOR y no CSA, `Timetable` en memoria sin migración de esquema.

### Hecho

- [x] **1/11 — `PlannerOptions` + `WalkModel`** (`b4edb59`)
  `VigoCore/Sources/VigoCore/Planner/PlannerOptions.swift`,
  `VigoCore/Sources/VigoCore/Planner/WalkModel.swift`.
  9 parámetros de política documentados. Conversión metros→segundos redondeando siempre
  hacia arriba. `footpaths(stops:)` con barrido por latitud, contrastado por test contra
  escaneo cuadrático completo (200 paradas, semilla fija).

- [x] **Fix de deuda, no planeado** — `f4a1282`
  `GTFSImporter.import` tomaba `Date()` real en vez del reloj que el llamador ya usaba;
  dos tests de `FeedServiceTests` solo pasaban antes de las 09:00 (Madrid). Ahora
  `import(importedAt:)` recibe el reloj, y `GTFSFeedService` le pasa el mismo `now` que usa
  para la hora de comprobación. Sin esto no se podía seguir con paso 2 con la suite verde.

- [x] **2/11 — `Timetable` + `TimetableBuilder`** (`1639109`)
  `VigoCore/Sources/VigoCore/Planner/Timetable.swift`,
  `VigoCore/Sources/VigoCore/Planner/TimetableBuilder.swift`.
  Snapshot en memoria, arrays CSR en `Int32`, sin migración de esquema. Pliega tres días de
  servicio sobre un eje temporal único; el desplazamiento entre días es la diferencia real
  entre medianoches (no 86400 fijo, por el cambio de hora). Separa patrones que se
  adelantan. Contra el feed real: 188 patrones, 1892 viajes, 70679 tiempos, 0,6 MB,
  construido en 34 ms — dentro del presupuesto de <1s con margen amplio.
  Verificado por mutación: desactivar la separación por adelantamiento tumba 4/15 tests.

- [x] **3/11 — `RaptorEngine`** (`e017e57`)
  `VigoCore/Sources/VigoCore/Planner/RaptorEngine.swift`.
  Función pura `(Timetable, RaptorQuery) -> RaptorResult`. Rondas = frente de Pareto
  (llegada, transbordos). Embarca con la etiqueta de la ronda anterior, no la actual. Un
  solo salto a pie por ronda (sin punto fijo — la desigualdad triangular lo hace seguro).
  Poda por objetivo desde el inicio.
  **Aviso importante:** los 14 tests iniciales pasaron a la primera. Se probaron 4
  mutaciones deliberadas del motor; 2 pasaban desapercibidas porque la red sintética de
  pruebas no tenía la forma para exponerlas (embarcar con etiqueta de ronda en curso;
  encadenar caminatas). Se amplió la red (parada E, línea L6) hasta que las 4 mutaciones
  fallan. Ver commit `e017e57` para el detalle — es la evidencia de que "tests en verde"
  no bastaba por sí solo.

### Pendiente (orden del plan)

- [ ] **4/11 — `BruteForceReference` + contraste aleatorizado.** El plan lo marca como
      "aquí es donde se gana la confianza": exploración exhaustiva sobre timetables
      pequeños, ~200 instancias con semilla fija. Es la red de seguridad real contra
      respuestas plausibles-pero-subóptimas — justo el tipo de fallo que el paso 3 mostró
      que los tests de ejemplo no cazan solos.
- [ ] 5/11 — Reconstrucción de viajes + pasada de ajuste hacia atrás + selección de
      alternativas.
- [ ] 6/11 — `TimetableStore` (actor con caché) + `JourneyPlanner` (fachada pública) +
      todos los `PlanOutcome` de fallo.
- [ ] 7/11 — Integración con el feed real + asserción de <1s en `RealFeedTimingTests`.
- [ ] 8/11 — App: cirugía de `RootView`, mover "Fuentes" a la barra de Favoritas,
      `AppEnvironment` gana el planificador y precalienta el timetable.
- [ ] 9/11 — `PlannerView` + `PlacePickerView`.
- [ ] 10/11 — `JourneyDetailView` con trazado real desde `shapePoint`.
- [ ] 11/11 — Anotación con tiempo real del primer embarque + actualizar tabla de estado
      de `README.md`.

---

## Cómo continuar

1. Lee `ILoveVigoRoutes-HANDOFF.md` §6 (Fase 3) y el plan completo en
   `~/.claude/plans/actua-como-un-planificador-immutable-parnas.md` para el detalle de
   arquitectura de cada paso pendiente.
2. Sigue el plan **tal cual**, un paso = un commit, compilando y con tests en verde antes
   de pasar al siguiente.
3. Al terminar un paso: actualiza este fichero (mover de "Pendiente" a "Hecho", anotar el
   hash del commit y cualquier desviación del plan con su porqué) y haz commit del
   `ESTADO.md` junto con el código.
4. Antes de dar un paso por bueno, desconfía de una tanda de tests que pase a la primera
   sin fallar nunca: prueba mutaciones puntuales del código nuevo (romper a mano una
   invariante concreta) y comprueba que algún test la caza. El paso 3 tenía dos huecos así
   — no son hipotéticos.
5. `swift test` corre en segundos y no toca red; es lo que se ejecuta en cada paso.
   Contra el feed real (necesario en el paso 7, opcional de sanity check en otros):
   ```bash
   curl -o /tmp/gtfs_vigo.zip https://datos.vigo.org/data/transporte/gtfs_vigo.zip
   cd VigoCore && VIGO_GTFS_ZIP=/tmp/gtfs_vigo.zip swift test -c release
   ```
6. Repo en `https://github.com/Turing0x/ILoveVigoRoutes.git`, rama `main`. Push solo
   cuando el usuario lo pida explícitamente.

## Verificación rápida del estado

```bash
cd VigoCore && swift test 2>&1 | tail -3
git log --oneline -5
```
Al escribir este documento: 144 tests, 15 suites, todo verde; árbol de trabajo limpio;
`main` sincronizado con `origin/main` en `e017e57`.
