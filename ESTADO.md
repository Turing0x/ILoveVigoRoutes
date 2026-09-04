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

- [x] **4/11 — `BruteForceReference` + contraste aleatorizado**
  `VigoCore/Tests/VigoCoreTests/BruteForceReference.swift`,
  `VigoCore/Tests/VigoCoreTests/BruteForceReferenceTests.swift`.
  Referencia exhaustiva (sin búsqueda binaria, sin cola de posiciones, cada patrón
  reescaneado entero cada ronda) contra timetables sintéticos aleatorios construidos
  directamente sobre los arrays de `Timetable` (sin pasar por GTFS), 200 instancias con
  semilla fija (`SeededGenerator`, splitmix64).
  **Encontró un bug real en `RaptorEngine`, no solo en la referencia**: el paso 4 de
  relajación de footpaths (`RaptorEngine.swift`) leía `arrival[base + stop]` en vivo como
  origen de cada caminata. Si una parada `X` alcanzada en bici/bus en esta ronda recibía
  además una caminata entrante *antes* de que le tocara su turno como origen (`X` está en
  `riddenStops`, solo que más adelante en la lista), esa lectura recogía el valor ya
  corregido por la caminata entrante en vez del de la subida — encadenando dos caminatas en
  una ronda sin que ninguno de los dos bucles lo notara, justo lo que el diseño prohíbe
  explícitamente («un solo salto a pie por ronda») y lo que el test
  `oneWalkPerRound` no cazaba porque solo mira el `parent` final, no los valores
  intermedios usados para calcularlo. Arreglado tomando una foto (`rideArrival: [Int:
  Int32]`) de las llegadas en bus antes de que el bucle de caminatas escriba nada; la
  referencia tenía el mismo fallo y se corrigió igual. Sin el contraste aleatorizado este
  bug no tenía ningún test que lo detectara — los 14+4 tests de ejemplo del paso 3 pasaban
  igual de verdes con o sin él.

- [x] **5/11 — Reconstrucción de viajes + ajuste hacia atrás + selección de alternativas**
  `VigoCore/Sources/VigoCore/Planner/Place.swift`, `Journey.swift`, `JourneyReconstruction.swift`;
  tests en `VigoCore/Tests/VigoCoreTests/JourneyReconstructionTests.swift`.
  `Place` (parada, o coordenada con etiqueta — ubicación/mapa) y `Journey`/`JourneyLeg` tal
  como los describe el plan. `JourneyReconstruction.alternatives` recorre los `parent` de
  `RaptorResult` hacia atrás por ronda (un `.ride` retrocede a la ronda anterior en la
  parada de subida, un `.walk` se queda en la misma ronda), arma la cadena hacia delante y
  aplica la pasada de ajuste: desde la llegada fija del último tramo, cada tramo en autobús
  se recalcula al **viaje más tardío** del mismo patrón que sigue llegando a tiempo, y el
  límite se propaga hacia atrás restando `minTransferSeconds` (mismo andén),
  `footpathBufferSeconds` + segundos de la caminata (transbordo a pie), o nada (tramo de
  acceso, que fija la hora de salida real). Una ronda por candidata (ya es frente de
  Pareto por construcción: más transbordos solo aparece si mejora la llegada), filtrado por
  `extraTransferWorthSeconds` contra la última alternativa aceptada, orden por llegada,
  tope de 3.
  Verificado por mutación: anular la pasada de ajuste (usar siempre el viaje ya encontrado)
  tumba el test dedicado con una red construida a propósito (tres viajes de un mismo patrón
  cada 5 minutos hacia una única conexión fija) — sin esa red los ejemplos del paso 3/4 no
  tenían margen suficiente para exponerlo, exactamente el mismo patrón de riesgo que ya
  apareció en los pasos anteriores.
  **Desviación del plan:** el fichero de test se llama `JourneyReconstructionTests.swift`,
  no `JourneyPlannerTests.swift` — ese nombre lo tomará el paso 6, cuando exista de verdad
  la fachada `JourneyPlanner` que el plan describe para ese fichero.

- [x] **6/11 — `TimetableStore` + `JourneyPlanner` + todos los `PlanOutcome`**
  `VigoCore/Sources/VigoCore/Planner/TimetableStore.swift`, `JourneyPlanner.swift`;
  tests en `JourneyPlannerTests.swift` (facade), `TimetableStoreTests.swift`.
  `TimetableStore` es el segundo actor del paquete (junto a `ThrottledRealtimeProvider`),
  pero más simple: `TimetableBuilder.build` no tiene ningún punto de suspensión dentro, así
  que la propia serialización del actor ya basta para que dos peticiones concurrentes
  esperen a una sola construcción — no hace falta el `inFlight`/`Task` que sí necesita
  `ThrottledRealtimeProvider` (esa sí llama a una red asíncrona real). Caché LRU de 3
  entradas, clave (día ancla, `feedStatus.importedAt`).
  `JourneyPlanner.plan` sigue el orden literal del plan: resuelve accesos/salidas por
  `nearbyStops` con el radio de acceso, comprueba ventana del feed y día de servicio, pide
  el `Timetable` al store, corre `RaptorEngine`, reconstruye con `JourneyReconstruction`, y
  decide entre `.journeys`, `.walkOnly` y `.noJourneyFound` comparando la caminata directa
  contra la mejor alternativa en autobús.
  **Desviación del plan, justificada:** el plan no dice cuándo `.noJourneyFound` debe
  ganarle a `.walkOnly` — tal cual estaba escrito ("si caminar es más rápido... walkOnly"),
  caminar siempre "gana" cuando no hay autobús, y `.noJourneyFound` quedaría inalcanzable
  pese a ser un caso que el propio plan pide probar. Añadido un límite: la caminata directa
  solo es una alternativa válida si tarda `<= options.searchHorizon` (el mismo presupuesto
  que ya usa la búsqueda en autobús); si no, y no hay autobús, es `.noJourneyFound`.
  Verificado por mutación: anular el recorte por capacidad de `TimetableStore` tumba el
  test de desalojo con un mismatch de contenido, no solo un contador.
  El nombre `JourneyPlannerTests.swift` que el paso 5 dejó pendiente para "cuando exista de
  verdad la fachada" ya está en uso, tal como el plan lo preveía.

- [x] **7/11 — Integración con el feed real + asserción de <1s**
  `VigoCore/Tests/VigoCoreTests/RealFeedIntegrationTests.swift` (ampliado).
  Nuevo test `realJourneyPlan`: Praza de América → Urzaiz (~1,3 km, centro de Vigo) con
  `JourneyPlanner` contra el archivo real, aceptando `.journeys`, `.walkOnly` o
  `.noServiceOnDay` (un hueco real de calendario no es un defecto) y fallando para
  cualquier otro caso. `RealFeedTimingTests.importTimings` añade la única asserción dura de
  la fase: `planElapsed < 1.0` sobre una construcción de `Timetable` **en frío** (el caso
  peor: nunca se había construido para ese día) más `RaptorEngine` más reconstrucción —
  medido: **40 ms** contra el feed real (1154 paradas, 3801 viajes, 137456 stopTimes),
  25× de margen sobre el presupuesto de 1s del handoff.
  **Detalle no obvio:** la consulta usa el día del propio `feed.serviceWindow`, no "hoy" —
  el archivo descargado es una foto fija y su ventana de 7 días no siempre incluye la fecha
  real en la que corre el test (el archivo usado aquí, descargado el 2026-09-04, reporta
  ventana 20260905–20260911, es decir *empieza mañana*). Usar `Date()` directamente habría
  dado `.outsideFeedWindow` de forma intermitente según cuándo se ejecute la suite.

### Pendiente (orden del plan)
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
Al escribir este documento: 163 tests, 19 suites, todo verde en local (sin feed real) y
también contra el feed real en `-c release` (`VIGO_GTFS_ZIP=/tmp/gtfs_vigo.zip`); árbol de
trabajo limpio antes del commit del paso 7/11.
