# Auditoría del motor de trayectos (RAPTOR)

Auditoría independiente del planificador RAPTOR y de toda la cadena que va del GTFS importado
a la lista de alternativas ordenadas. Encargo en `AUDITORIA-RAPTOR-PROMPT.md`.

Ningún fichero del repositorio ha sido modificado. Todo el código de verificación —generadores
aleatorios, oráculo exhaustivo puerta a puerta, mutaciones— vive fuera del repo, en una copia
desechable del paquete.

---

## 1. Resumen ejecutivo

El **núcleo del algoritmo está bien**. Contrastado contra la referencia exhaustiva sobre
**20.000 instancias aleatorias y 40 semillas**, con formas de red que el generador actual no
sabe producir: **cero discrepancias** siempre que se cumple la precondición de no adelantamiento,
y 174 discrepancias exactamente cuando la rompo a propósito — que es la demostración de que
`TimetableBuilder.nonOvertakingGroups` es carga estructural y no adorno. Ese constructor lo
fuzzeé aparte: 20.000 instancias, 36.013 grupos, **cero violaciones**. El ajuste hacia atrás es
correcto (0 fallos con oráculo estricto). El rendimiento no es un problema: 21 ms en caliente,
108 ms en frío contra el feed real, con presupuesto de 1 s.

**Lo que está roto está en la reconstrucción, no en la búsqueda.** Los dos primeros hallazgos
son graves, se disparan en el feed real y ningún test los ve:

1. **H-01** — `Journey.arrival` ignora toda caminata posterior al último tramo en bus. En el
   feed real afecta al **71,6 % de las alternativas** (1.966 de 2.746), con un error máximo de
   **1.071 s (17 min 51 s)**. Es la hora que el usuario lee en pantalla, y alimenta la
   dominancia, los tres criterios de orden y la decisión `walkOnly`.
2. **H-02** — `reconstruct` encadena caminatas siguiendo punteros `parent` que quedaron obsoletos.
   Produce trayectos con hasta **cuatro caminatas seguidas entre paradas (1,4 km)** presentados
   como un transbordo, y de una línea distinta de la que el motor calculó. 1,8 % de las
   alternativas del feed real.
3. **H-03** — la poda por `targetBest` mata al candidato de bajada que menos te hace andar en
   cuanto necesita una ronda más. El candidato que la Fase 10 existe para producir **no se
   genera**, y `egressCandidates` no puede arreglarlo porque la etiqueta no existe.

Arreglé H-01, H-02 y H-06 en la copia desechable: **la suite de 321 tests sigue verde**, las
caminatas encadenadas del feed real pasan de 1,8 % a **0 %** y los errores de hora de 329 a **0**
sobre las instancias aleatorias. El diff mínimo está en §4.

---

## 2. Qué pude ejecutar

| | |
|---|---|
| **Feed real** | **Sí.** `/private/tmp/gtfs_vigo.zip`, 17.236.188 bytes, ficheros de 2026-09-04, ventana **20260905–20260911**. 1.154 paradas, 3.801 viajes, 137.456 `stop_times`, 59 rutas (45 con viajes). Nada en este informe marcado como medido es razonamiento disfrazado. |
| **Suite de partida** | 321 tests, 39 suites, **verde**, 0,16 s de ejecución (2,0 s con compilación). |
| **Contraste aleatorizado** | **20.000 instancias, 40 semillas** (la suite envía 200 con una semilla), con generador ampliado a 7 formas de red nuevas. 4,2 s. |
| **Fuzz de `nonOvertakingGroups`** | 20.000 instancias, 36.013 grupos producidos, 0,35 s. |
| **Oráculo puerta a puerta** | Enumeración exhaustiva de trayectos completos sobre 9.000 instancias pequeñas; 973 con alternativas que comparar. Nuevo: hoy no existe ningún oráculo más allá de las etiquetas de llegada. |
| **Mutaciones** | **19 aplicadas una a una**, con `swift test` completo en cada una y reversión después. **5 sobreviven.** |
| **Medición sobre el feed real** | 577 planificaciones reales (14 puntos de Vigo × 4 horas), 2.746 alternativas analizadas una a una. |
| **Comprobación de los arreglos** | Suite completa + oráculo + feed real, con los tres parches aplicados. |

**Qué no pude comprobar:** nada del target de app (fuera de alcance); el comportamiento en las
dos semanas de cambio de hora contra datos reales (el feed disponible cubre septiembre — el
análisis de §H-08 es aritmética de calendario medida, no una planificación real en esas fechas);
y la reproducción en dispositivo.

---

## 3. Tabla de hallazgos

| # | Título | Sev. | Conf. | Categoría | Fichero |
|---|---|---|---|---|---|
| H-01 | `Journey.arrival` no cuenta las caminatas posteriores al último bus | **crítica** | alta | corrección | `JourneyReconstruction.swift:298` |
| H-02 | La reconstrucción encadena caminatas siguiendo `parent` obsoletos | **crítica** | alta | invariante | `RaptorEngine.swift:206`, `JourneyReconstruction.swift:193` |
| H-03 | La poda por `targetBest` elimina el candidato de menos caminata | alta | alta | optimalidad | `RaptorEngine.swift:159` |
| H-04 | `alternatives` recorta por llegada antes de que exista el criterio | media | alta | invariante | `JourneyReconstruction.swift:77` |
| H-05 | El eje `departure` de la dominancia no es el `earliestBoarding` del orden | media | alta | corrección | `JourneyShortlist.swift:32` |
| H-06 | `reconstruct` no tiene guarda de ciclo ni cota de longitud | media | alta | invariante | `JourneyReconstruction.swift:193` |
| H-07 | Las tres condiciones de mejora estricta no las cubre ningún test | media | alta | testabilidad | `RaptorEngine.swift:159,179,212` |
| H-08 | El desplazamiento entre días por cambio de hora no tiene test | media | alta | testabilidad | `TimetableBuilder.swift:73` |
| H-09 | La cláusula de `departures` en `overtakes` no tiene test | baja | alta | testabilidad | `TimetableBuilder.swift:301` |
| H-10 | No se relajan footpaths en la ronda 0, y la poda global remata la pérdida | baja | media | optimalidad | `RaptorEngine.swift:105` |
| H-11 | `nearbyStops` corta a 40 en silencio, y en Vigo el tope se alcanza | baja | alta | corrección | `TransitRepository.swift:163` |
| H-12 | `TimetableBuilder.build` bloquea un hilo cooperativo ~108 ms | baja | alta | concurrencia | `TimetableStore.swift:44` |
| H-13 | El constructor no verifica sus propias precondiciones sobre los tiempos | baja | alta | deuda | `TimetableBuilder.swift:245` |
| H-14 | `?? ride.trip` del ajuste hacia atrás es código muerto | nit | alta | deuda | `JourneyReconstruction.swift:241` |
| H-15 | `TimetableStore.invalidateAll()` no lo llama nadie | nit | alta | deuda | `TimetableStore.swift:56` |
| H-16 | Los `&+`/`&-` son seguros por construcción, pero nada lo dice ni lo comprueba | nit | alta | aritmética | `RaptorEngine.swift` (todo) |
| H-17 | `exitKey` es un hash a mano que colisiona por encima de 10⁶ paradas | nit | alta | deuda | `JourneyReconstruction.swift:85` |
| H-18 | Ordenaciones no estables en empates de tres sitios | nit | media | determinismo | `JourneyReconstruction.swift:139` |
| H-19 | `walkOnly` esconde todos los autobuses, incluso bajo «menos caminata» | nit | alta | corrección | `JourneyPlanner.swift:128` |

---

## 4. Hallazgos en detalle

### H-01 · `Journey.arrival` no cuenta las caminatas posteriores al último bus

**JourneyReconstruction.swift:298-305** · **Severidad:** crítica · **Confianza:** alta ·
**Categoría:** corrección

**Qué pasa.** Cuando la cadena de un trayecto termina con una caminata de transbordo —el motor
llega en bus a X y camina a la parada Y, y es Y la parada de bajada elegida—, la hora de llegada
que se publica es *la del bus a X* más la caminata final, **saltándose la caminata X→Y**. Los
tramos que se dibujan en pantalla sí la incluyen, así que la ficha se contradice a sí misma: la
lista de tramos suma más que la hora grande que la encabeza.

Medido sobre el feed real, 577 planificaciones y **2.746 alternativas**:

| Subestimación | Alternativas |
|---|---|
| < 1 min | 388 |
| 1–3 min | 686 |
| 3–5 min | 793 |
| ≥ 5 min | 99 |
| **Total afectado** | **1.966 (71,6 %)** |

Peor caso medido: **1.071 s = 17 min 51 s**.

**Instancia mínima.** Ejecutada:

```swift
// 0 --L1--> 1 (llega 33000); footpath 1<->2 (120 s); el destino está a 60 s de la parada 2.
let stops = [Audit.stop(0), Audit.stop(1, east: 2000), Audit.stop(2, east: 2100)]
let tt = Audit.timetable(
    stops: stops,
    patterns: [.init(route: "L1", stops: [0, 1], times: [[32_400, 33_000]])],
    footpaths: [(1, 2, 120)])
let q = RaptorQuery(access: [StopWalk(stop: 0, seconds: 0)],
                    egress: [StopWalk(stop: 2, seconds: 60)],
                    departure: 32_400, horizon: 10_800)
```

Salida observada:

```
etiqueta RAPTOR en la parada 2, ronda 1 = 33120     (bus 33000 + caminata 120)
egressCandidates                        = [(round: 1, stop: 2, seconds: 60, arrival: 33180)]
Journey reconstruido: arr=33060
  walk(S0->S0, 0s) + ride(L1 S0@32400 -> S1@33000) + walk(S1->S2, 120s) + walk(S2->Puerta, 60s)
```

`33060` en vez de `33180`: **120 s de menos**, exactamente la caminata de transbordo. Y el propio
`EgressCandidate` que produjo este trayecto ya llevaba el `33180` correcto — la pérdida ocurre
después, al construir el `Journey`.

En el feed real (Castrelos → Guixar, 18 h) el mismo defecto, agravado por H-02:

```
arr=67983  |  ... ride(23 ... -> Rúa de Pizarro 16@67441)
              + walk(->Avda. da Gran Vía 19, 304s) + walk(->Rúa de Urzáiz 28, 269s)
              + walk(->Avda. de García Barbón 28, 247s) + walk(->Rúa do Canceleiro 6, 251s)
              + walk(->Guixar, 542s)
```

67441 + 304 + 269 + 247 + 251 + 542 = **69054**, no 67983.

**Por qué pasa.** `JourneyReconstruction.swift:298-305` toma la llegada del **último tramo en
bus** y le suma solo la caminata de salida:

```swift
let lastRide = rides[rides.count - 1]
let networkArrival = timetable.arrival(pattern: lastRide.pattern, trip: lastRide.trip,
                                       position: lastRide.alightPosition)
return Journey(..., arrival: timetable.date(forAxisSeconds: Int(networkArrival &+ egressSeconds)), ...)
```

Entre ese `lastRide` y `egressStop` puede haber uno o más pasos `.walk` en la cadena, y ninguno
entra en la cuenta. La variable se llama `networkArrival` —la llegada *a la red*— pero se usa
como si fuera la llegada a la parada de bajada, que es otra cosa en cuanto hay un footpath.

**Consecuencias más allá de la hora en pantalla.** `Journey.arrival` es un eje de
`JourneyShortlist.undominated`, el criterio primario de `earliestArrival`, el desempate de
`leastWalkAtEnd` y de `earliestBoarding`, la clave de ordenación de `cut` y de `alternatives`, y
el número que `JourneyPlanner.plan:129` compara contra la caminata directa para decidir
`.walkOnly`. Un trayecto con la llegada adelantada 5 minutos **desplaza injustamente a otros y
puede impedir que se ofrezca `walkOnly` cuando caminar sí era más rápido**.

**Cómo lo arreglaría.** Sumar todas las caminatas posteriores al último bus:

```swift
var networkArrival = timetable.arrival(pattern: lastRide.pattern, trip: lastRide.trip,
                                       position: lastRide.alightPosition)
if let lastRideLeg = chain.lastIndex(where: {
    if case .ride = $0.parent { return true }; return false }) {
    for step in chain[(lastRideLeg + 1)...] {
        if case .walk(_, let seconds) = step.parent { networkArrival &+= seconds }
    }
}
```

Verificado: con este cambio, `Journey.arrival` coincide con la etiqueta de RAPTOR y con la suma
de los tramos en **las 973 instancias** del oráculo (antes: 329 discrepancias) y la suite de 321
tests sigue verde.

**Cómo lo verificaría.** Test en `JourneyReconstructionTests.swift`: la red de la instancia
mínima de arriba, comprobando `journey.arrival == 33180` **y** que
`journey.arrival == último .ride.arrival + suma de los .walk posteriores`. Mutación que debe
tumbarlo: volver a `networkArrival &+ egressSeconds` a secas. Mejor todavía, una propiedad
general en `JourneyReconstructionTests`: para toda alternativa devuelta, la llegada declarada
tiene que ser reconstruible desde sus propios tramos — es una invariante barata que cierra toda
esta clase de fallo, no solo este caso.

---

### H-02 · La reconstrucción encadena caminatas siguiendo punteros `parent` obsoletos

**RaptorEngine.swift:206-219** y **JourneyReconstruction.swift:193-205** · **Severidad:** crítica ·
**Confianza:** alta · **Categoría:** invariante

**Qué pasa.** El diseño promete **un salto a pie por ronda** («encadenar caminatas convertiría un
transbordo en una caminata de 900 m» — invariante 5, y el paso 3/11 de la Fase 3 dice que se
amplió la red de pruebas hasta que esa mutación fallaba). El motor **calcula** bien: sus etiquetas
coinciden con la referencia exhaustiva en 20.000 instancias. Pero sus **punteros `parent` mienten**,
y la reconstrucción los sigue, produciendo trayectos con dos, tres y cuatro caminatas seguidas.

En el feed real: **49 de 2.746 alternativas (1,8 %)**. Peor caso, Castrelos → Guixar a las 18 h:

```
ride(23 ... -> Rúa de Pizarro 16@67441)
  + walk(Rúa de Pizarro 16      -> Avda. da Gran Vía 19,        304s)
  + walk(Avda. da Gran Vía 19   -> Rúa de Urzáiz 28,            269s)
  + walk(Rúa de Urzáiz 28       -> Avda. de García Barbón 28,   247s)
  + walk(Avda. de García Barbón 28 -> Rúa do Canceleiro 6,      251s)
  + walk(Rúa do Canceleiro 6    -> Guixar,                      542s)
```

**Cuatro footpaths encadenados: 1.071 s ≈ 18 minutos, del orden de 1,4 km a pie**, ofrecidos como
si fueran un transbordo, con `transfers=0` y con la hora de llegada de H-01. Es exactamente el
resultado que `maxTransferWalkMetres = 300` existe para impedir.

**Instancia mínima.** Ejecutada, y aísla la causa sin ruido:

```swift
// Ronda 1: L1 llega a s1 a 33000; L2 llega a s2 a 33600.
// Footpath s1<->s2 (120 s) mejora s2 a 33120 y le reescribe el parent.
// Footpath s2<->s3 (60 s) sale de s2 usando rideArrival[s2] = 33600 -> 33660.
let stops = [Audit.stop(0), Audit.stop(1, east: 2000), Audit.stop(2, east: 2100),
             Audit.stop(3, east: 2200), Audit.stop(4, north: 500)]
let tt = Audit.timetable(stops: stops, patterns: [
    .init(route: "L1", stops: [0, 1], times: [[32_400, 33_000]]),
    .init(route: "L2", stops: [4, 2], times: [[32_400, 33_600]]),
], footpaths: [(1, 2, 120), (2, 3, 60)])
let q = RaptorQuery(access: [StopWalk(stop: 0, seconds: 0), StopWalk(stop: 4, seconds: 0)],
                    egress: [StopWalk(stop: 3, seconds: 30)], departure: 32_400, horizon: 10_800)
```

Salida observada:

```
etiqueta en s3 = 33660          <- rideArrival[s2] 33600 + 60. Puerta a puerta: 33690.
parent[s2]     = walk(from: 1, seconds: 120)   <- pero lo que salió de s2 fue su BUS de las 33600
parent[s3]     = walk(from: 2, seconds: 60)

reconstruido: arr=33030
  walk(Casa->S0, 0s) + ride(L1 S0@32400 -> S1@33000) + walk(S1->S2, 120s)
                     + walk(S2->S3, 60s) + walk(S3->Puerta, 30s)
```

El trayecto correcto es *coger L2 de s4 a s2 llegando a 33600, andar 60 s a s3, andar 30 s a la
puerta*: llegada 33690, **una** caminata. Lo que se devuelve es otra línea (L1 en vez de L2), dos
caminatas encadenadas y una llegada 660 s antes de la real.

**Por qué pasa.** Es el mismo agujero que el paso 4/11 de la Fase 3 documenta, arreglado a
medias. `RaptorEngine.swift:202-204` toma la foto de las llegadas en bus antes de que el bucle de
caminatas escriba nada:

```swift
var rideArrival: [Int: Int32] = [:]
for stop in riddenStops { rideArrival[stop] = arrival[base + stop] }
```

y luego, en `:207`, cada parada usa `rideArrival[stop]` como origen. **El valor está protegido; el
puntero no.** En `:216` una caminata entrante hace

```swift
parent[base + target] = .walk(from: Int32(stop), seconds: seconds)
```

sobre una parada `target` que también está en `riddenStops`. Cuando a `target` le llega su turno
como origen, sale con su hora de bus (correcto) pero **su `parent` ya dice que se llegó a ella
andando**. `JourneyReconstruction.swift:201-202` sigue ese `parent`:

```swift
case .walk(let from, _):
    stop = Int(from)          // no decrementa la ronda: se queda en la misma
```

y encadena tantos saltos como punteros reescritos haya en esa ronda. Nada acota la cadena.

Que las etiquetas sean correctas es justamente lo que hace invisible el fallo: `BruteForceReference`
solo compara **valores de llegada**, nunca punteros ni trayectos, así que el contraste
aleatorizado —la herramienta que cazó el bug hermano en la Fase 3— pasa igual de verde.

**Cómo lo arreglaría.** Guardar el `parent` en la misma foto que ya se guarda del valor, y
resolver un `.walk(from: S)` contra el `parent` que S tenía **cuando su valor salió**:

```swift
// RaptorEngine: junto a rideArrival
for stop in riddenStops {
    rideArrival[stop] = arrival[base + stop]
    rideParent[base + stop] = parent[base + stop]
}
// ... y se publica en RaptorResult.

// JourneyReconstruction: al seguir la cadena
while let parent = cameFromWalk
        ? result.rideParent(round: currentRound, stop: stop)
        : result.parent(round: currentRound, stop: stop) {
```

Es correcto porque un `.walk(from: S)` **solo** se escribe en el bucle de caminatas, donde S está
por construcción en `riddenStops` y por tanto tiene un `parent` de tipo `.ride` en esa ronda.

Verificado: instancia mínima corregida (devuelve L2, llegada 33690, una caminata); caminatas
encadenadas en el feed real **de 49 a 0**; en el oráculo, de 24 a 0 sobre 973 instancias; suite de
321 tests verde.

**Cómo lo verificaría.** Test en `RaptorEngineTests.swift` con la red de la instancia mínima,
afirmando que el trayecto devuelto usa **L2** y tiene exactamente un tramo a pie entre paradas.
Mutación que debe tumbarlo: quitar la foto de `rideParent` (leer `result.parent` siempre). Y una
propiedad en `JourneyReconstructionTests`: ninguna alternativa contiene dos `.walk` consecutivos
cuyos dos extremos sean paradas — barata, general, y habría cazado esto desde el primer día.

---

### H-03 · La poda por `targetBest` elimina el candidato de menos caminata

**RaptorEngine.swift:159 y 222** · **Severidad:** alta · **Confianza:** alta ·
**Categoría:** optimalidad

**Qué pasa.** `targetBest` se aprieta al final de cada ronda con la mejor llegada **puerta a
puerta** encontrada hasta ahí. En la ronda siguiente, toda etiqueta que llegue igual o más tarde
se descarta. Eso es correcto para un frente de Pareto de dos dimensiones (llegada, transbordos),
que es lo que el comentario de `:233-236` argumenta — y era cierto hasta la Fase 10. Desde la
Fase 10 hay un **tercer eje**, la caminata final, y la poda no lo conoce: descarta paradas de
bajada que llegan más tarde pero dejan mucho más cerca. Es el fallo del §10.3 del plan, un nivel
por debajo de donde la Fase 10 lo arregló: `egressCandidates` no puede rescatar un candidato cuya
etiqueta el motor nunca escribió.

Medido: en **52 de 973** instancias del oráculo (5,3 %) la parada que menos caminata deja
**no la alcanza el motor en absoluto**. Son el 98 % de todos los casos en los que el óptimo de
«menos caminata» falta.

**Instancia mínima.** Ejecutada:

```swift
// 0 -L1-> 1  (lejos del portal, 900 s a pie)   llega 33000, puerta a puerta 33900
// 1 -L2-> 2  (al lado del portal, 30 s a pie)  llega 34200, puerta a puerta 34230
let stops = [Audit.stop(0), Audit.stop(1, east: 2000), Audit.stop(2, east: 2600)]
let tt = Audit.timetable(stops: stops, patterns: [
    .init(route: "L1", stops: [0, 1], times: [[32_400, 33_000]]),
    .init(route: "L2", stops: [1, 2], times: [[33_600, 34_200]]),
])
let q = RaptorQuery(access: [StopWalk(stop: 0, seconds: 0)],
                    egress: [StopWalk(stop: 1, seconds: 900), StopWalk(stop: 2, seconds: 30)],
                    departure: 32_400, horizon: 10_800)
```

Salida observada:

```
roundsRun = 1   bestArrival = [32400, 33000, 2147483647]
etiqueta en la parada 2, ronda 2 = nil          <- debería ser 34200
egressCandidates = [(round: 1, stop: 1, seconds: 900, arrival: 33900)]
```

La parada 2 —la que te deja a 30 segundos del portal— **es inalcanzable para el motor**. La única
alternativa ofrecida te hace andar **15 minutos**. Bajo el criterio por defecto, «Menos caminata»
ofrece la opción de 900 s porque la de 30 s no existe.

**Por qué pasa.** Al final de la ronda 1, `RaptorEngine.swift:222` hace
`targetBest = min(targetBest, bestEgress(...))`, y `bestEgress` (`:237-246`) minimiza
`bestArrival[salida] + salida.seconds` sobre **todas** las salidas: `min(33000+900, ∞) = 33900`.
En la ronda 2, `:159` evalúa `arrives < min(bestArrival[stop], targetBest)` con `arrives = 34200`
y `targetBest = 33900` → falso, no se escribe. `roundsRun` se queda en 1.

El razonamiento del comentario —«un trayecto que no llega antes usando más vehículos está
dominado»— era válido cuando la única figura de mérito era la llegada. Con la caminata final como
criterio por defecto, un trayecto que llega más tarde **no** está dominado si te deja más cerca:
ese es literalmente el caso X/Y que `JourneyShortlist.undominated` documenta en sus propias líneas
18-23. La poda lo mata antes.

**Cómo lo arreglaría.** El cambio mínimo y honesto es aflojar la cota a **la llegada a la red**,
no puerta a puerta: podar contra `min sobre las salidas de (bestArrival[salida])`, sin sumar la
caminata. Se conserva casi toda la poda (la que hace que una consulta imposible sea barata) y deja
de descartar paradas que compran cercanía con tiempo. Coste: más etiquetas por ronda; con 3,89 ms
por pasada y presupuesto de 1 s, hay margen de sobra.

Alternativa más correcta y más cara: hacer `targetBest` un frente de dos dimensiones (llegada,
caminata restante) y podar solo contra su envolvente. Es rediseñar la poda y toda su verificación;
no la recomiendo antes de medir que la primera opción no basta.

**Cómo lo verificaría.** Test en `RaptorEngineTests.swift` con la red de arriba: la parada 2 tiene
etiqueta en la ronda 2, y `egressCandidates` devuelve **dos** candidatos. Mutación que debe
tumbarlo: volver a podar con la caminata de salida incluida. Y una comprobación de regresión en
`EgressCandidatesTests` con un transbordo de por medio — la prueba actual («Una parada que llega
más tarde pero deja más cerca también se reconstruye») usa **una sola ronda**, que es justo el
caso donde la poda todavía no ha apretado.

---

### H-04 · `alternatives` recorta por llegada antes de que exista el criterio

**JourneyReconstruction.swift:77-79** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** invariante

**Qué pasa.** El encargo pide comprobar «si hay algún recorte anterior en la cadena que ya haya
decidido por llegada». **Lo hay**, y es el último gesto de `alternatives`:

```swift
return Array((kept + closerOnFoot)
    .sorted { $0.arrival < $1.arrival }
    .prefix(options.maxCandidates))
```

Ordenar por llegada y quedarse con los primeros es exactamente lo que la Fase 10 prohibió y lo que
`JourneyShortlist.cut` está escrito para evitar — 30 líneas de comentario en `JourneyShortlist.swift:42-51`
explican por qué. Y los candidatos que este `prefix` tira primero son, por construcción, los
`closerOnFoot`: son los que compran cercanía a cambio de tiempo, así que **son siempre los últimos
por llegada**.

**Con qué frecuencia muerde.** Medido sobre el feed real: `maxRounds × maxEgressCandidates = 4 × 3
= 12` candidatos posibles contra un corte de `maxCandidates = 8`. En **34 de 168 pasadas de RAPTOR
(20 %)** se generan más de 8 y el corte actúa. Máximo observado: 12 candidatos.

**Instancia mínima.** Ejecutada. Una línea que para en doce paradas, cada una más tarde y más cerca
del portal, así que las doce están en el frente de Pareto:

```swift
let n = 12
// paradas 1..12, la línea llega a cada una 120 s después que a la anterior
let egress = (1...n).map { StopWalk(stop: Int32($0), seconds: Int32((n - $0 + 1) * 100)) }
var opts = PlannerOptions(maxEgressCandidates: n)
```

Salida observada:

```
frente de Pareto = 12   caminatas [1200, 1100, ..., 200, 100]
con maxCandidates = 8 : caminatas ofrecidas [500, 600, 700, 800, 900, 1000, 1100, 1200]
con el corte quitado  : caminatas ofrecidas [100, 200, 300, ..., 1200]
«Menos caminata» ofrece 500 s; el candidato de 100 s se generó y se tiró.
```

**Honestidad sobre el alcance.** Con los valores por defecto **no conseguí que este corte perdiera
el óptimo de caminata en el feed real**: 0 de 168 pasadas, aunque muerda en 34. La razón es que la
misma parada de bajada reaparece en varias rondas y `seenExits` la conserva por la de llegada más
temprana. Así que es un **defecto real y alcanzable por construcción, hoy latente con estos datos
y estos números**. Lo reporto porque es precisamente el tipo de cosa que un cambio de
`maxEgressCandidates`, de `maxRounds` o del feed convierte en activo sin que ningún test se entere,
y porque el principio que viola está escrito tres veces en este repositorio.

**Por qué pasa.** El comentario de `:75-76` dice «cortado por `maxCandidates` y no por
`maxAlternatives`: esta es la reserva de la que elige la preferencia». Corrige el **tamaño** del
corte pero no su **criterio**: sigue siendo por llegada, y sigue estando antes de que exista una
preferencia.

**Cómo lo arreglaría.** Usar la herramienta que ya existe y que ya está probada:

```swift
return JourneyShortlist.cut(kept + closerOnFoot, to: options.maxCandidates)
```

`cut` reparte por turnos entre los tres criterios y garantiza que el óptimo de cada uno sobrevive;
además devuelve la lista ordenada por llegada, así que los llamadores que leen `first` como «la más
temprana» no cambian. `JourneyPlanner.ranked` ya lo llama después; llamarlo aquí también es
idempotente en lo que importa.

**Cómo lo verificaría.** El test de la instancia mínima en `EgressCandidatesTests.swift`: con doce
candidatos en el frente y `maxCandidates = 8`, el de menos caminata está entre los ocho. Mutación
que debe tumbarlo: volver a `.sorted { $0.arrival < $1.arrival }.prefix(...)`. Es la misma
mutación que `JourneyShortlist` ya tiene cubierta un nivel más arriba —«El corte reparte entre
criterios y conserva el óptimo de cada uno»—, lo que hace más llamativo que aquí abajo no lo esté.

---

### H-05 · El eje `departure` de la dominancia no es el `earliestBoarding` del orden

**JourneyShortlist.swift:32-35** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** corrección

**Qué pasa.** `undominated` usa `Journey.departure` («cuándo hay que echar a andar») como eje de
dominancia, mientras `JourneyOrdering.earliestBoarding` usa `firstBoarding` («cuándo pasa el
autobús»). El propio proyecto insiste en que **no son lo mismo**: el §10.1 del plan lo llama «la
mitad del trabajo de esta fase», `JourneyOrdering.swift:102-104` lo repite, y `FirstBoardingMatch.hasDeparted`
lo repite otra vez. Pero la dominancia se quedó con el eje viejo.

Consecuencia: **`undominated` puede borrar el trayecto que coge el primer autobús**, y entonces
«Sale antes» ordena una lista de la que el óptimo ya ha desaparecido. La rotación de
`JourneyShortlist.cut` no lo salva: protege el óptimo de cada criterio del *corte*, no del filtro
de dominadas que corre antes (`JourneyPlanner.swift:199`).

**Instancia mínima.** Ejecutada:

```swift
// A: 60 s de caminata de acceso, embarca 33000  -> Journey.departure = 32940
// B: 600 s de caminata de acceso, embarca 32700 -> Journey.departure = 32100
// misma llegada, mismos transbordos, misma caminata final.
```

Salida observada:

```
A embarca 33000, departure 32940
B embarca 32700, departure 32100
supervivientes de undominated      = [33000]          <- B eliminado
orden de «Sale antes» sobre ellos  = [33000]
```

B **es** el trayecto que coge el primer autobús (32700 < 33000), y es el que «Sale antes» debería
poner arriba. A lo domina porque sale de casa más tarde (32940 > 32100), que bajo el eje
`departure` cuenta como mejor. El usuario que elige «Sale antes» ve como primer bus uno que sale
cinco minutos después del primero que existe.

**Por qué pasa.** `:32` exige `a.departure >= b.departure`. Como `departure = embarque − acceso` y
el acceso es distinto en cada alternativa, el orden por `departure` y el orden por embarque pueden
discrepar en cualquier dirección. Que las dos nociones convivan no es un descuido de nadie —el
§10.1 argumenta bien por qué «salir más tarde de casa» es preferible a igualdad de todo lo demás—;
el problema es que la dominancia use una y la ordenación la otra, de modo que la primera decide
sobre un eje que la segunda no reconoce.

**Cómo lo arreglaría.** Dos opciones legítimas, y la elección es del propietario:

- **Cinco ejes:** añadir `firstBoarding` (antes mejor) al lado de `departure` (más tarde mejor).
  Es literalmente lo que hizo la Fase 10 con la caminata, por la misma razón: un criterio ofrecido
  en el menú necesita su eje en la dominancia o su óptimo se pierde. Coste: menos dominancia,
  frente mayor — que `cut` ya sabe recortar sin sesgo.
- **Quitar `departure` de la dominancia** y dejarlo solo como desempate de `earliestArrival`. Más
  simple, y defendible: «salgo de casa más tarde» es una comodidad, no una dimensión de optimalidad.

Recomiendo la primera: es coherente con lo ya decidido y no quita nada.

**Cómo lo verificaría.** Test en `JourneyShortlistTests`/`JourneyOrderingTests` con las dos
alternativas de arriba: **ambas sobreviven** a `undominated`, y `earliestBoarding` pone primero la
que embarca a 32700. Mutación que debe tumbarlo: quitar el eje de embarque otra vez. Es el
análogo exacto del test «Con cuatro ejes, el que anda menos sobrevive al filtro de dominadas» que
ya existe y que sí caza su mutación (m14, 4 tests rojos).

---

### H-06 · `reconstruct` no tiene guarda de ciclo ni cota de longitud

**JourneyReconstruction.swift:193-205** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** invariante

**Qué pasa.** El bucle que sigue los `parent` hacia atrás no acota nada. Un `.ride` decrementa
`currentRound` y un `.access` corta, pero un `.walk` **se queda en la misma ronda**, así que un
par de punteros `A → B → A` es un bucle infinito que hace crecer `chain` hasta agotar la memoria.

Hoy no es alcanzable, y la razón es fina: las escrituras del motor usan `<` estricto, y una
caminata A→B que mejore B y otra B→A que mejore A exigirían `s(A,B) + s(B,A) < 0`, imposible con
segundos no negativos. **Pero esa protección no está escrita en ninguna parte, no está probada, y
depende de un carácter en otro fichero.**

**Instancia mínima.** Ejecutada, en dos partes.

*Que el ciclo cuelga:* con una tabla `parent` construida a mano en la que las paradas 1 y 2 dicen
cada una que se llegó a ella andando desde la otra, `alternatives` **no vuelve nunca**:

```
✘ "Y1 — reconstruct against a walk cycle in the parent pointers":
  Time limit was exceeded: 60.000 seconds
```

*Que el carácter que lo impide no está protegido:* la mutación **m02**, que cambia el `<` de la
relajación de footpaths (`RaptorEngine.swift:212`) por `<=`, **no la caza ningún test de los 321**.
Y con esa mutación aplicada, dos paradas gemelas —mismo punto, footpath de 0 s, cosa que el feed
real tiene a montones— producen el ciclo:

```
MUT parents ronda 1: [nil, walk(from: 2, seconds: 0), walk(from: 1, seconds: 0), nil]
MUT punteros de caminata mutuos (el ciclo del que reconstruct no sale): true
```

Es decir: **un `<` convertido en `<=` en un fichero cuelga la app en otro, y la suite entera pasa
en verde.**

**Por qué pasa.** `:201-202` no toca `currentRound` para un `.walk`, y `:193` no lleva contador ni
conjunto de visitados. La condición de salida (`currentRound < 0`) solo la mueven los `.ride`.

**Cómo lo arreglaría.** Una cota, no una prueba de teoremas:

```swift
guardCounter += 1
if guardCounter > (result.roundsRun + 2) * result.stopCount { return nil }
```

Ningún trayecto legítimo visita más de una vez cada (ronda, parada), así que la cota no puede
rechazar nada válido, y `nil` ya es un valor que el llamador sabe saltar (lo introdujo la Fase 10).
Verificado: con la guarda, la instancia del ciclo devuelve en milisegundos y la suite sigue verde.

**Cómo lo verificaría.** El propio test Y1: construir un `RaptorResult` con punteros de caminata
mutuos y afirmar que `alternatives` devuelve (con `.timeLimit`). Mutación que debe tumbarlo: quitar
la guarda. Aparte, y con más valor: **un test para la propia condición estricta**, que es lo que
H-07 pide.

---

### H-07 · Las tres condiciones de mejora estricta no las cubre ningún test

**RaptorEngine.swift:159, 179, 212** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Qué pasa.** Tres mutaciones de un carácter sobreviven a la suite completa **sin un solo test
rojo**:

| Mutación | Línea | Cambio | Tests rojos |
|---|---|---|---|
| m01 | `:159` | `arrives < min(...)` → `<=` | **0** |
| m02 | `:212` | `candidate < min(...)` → `<=` | **0** |
| m03 | `:179` | `current > boardable` → `>=` | **0** |

Las tres son la misma idea: «mejora estricta». Lo que protegen no son los valores de llegada —que
no cambian, y por eso `BruteForceReference`, que solo compara valores, tampoco las ve— sino
**quién gana los empates y, por tanto, qué `parent` se registra y qué trayecto se reconstruye**.

- **m01** deja que el último patrón escaneado se lleve el empate, así que la línea que se muestra
  pasa a depender del orden de los patrones. Rompe el determinismo de la invariante 7 sin cambiar
  una sola hora.
- **m02** es la peligrosa: además de lo anterior, habilita los punteros de caminata mutuos que
  **cuelgan `reconstruct`** (H-06, demostrado arriba).
- **m03** cambia a qué viaje del patrón se salta cuando dos salen a la misma hora: mismo horario,
  distinto `tripID` y distinto `headsign` en pantalla.

**Instancia mínima.** No hace falta construir una: la instancia es la suite entera, y el resultado
es que ninguno de sus 321 tests distingue el código correcto del mutado. La demostración de la
consecuencia de m02 está en H-06.

**Por qué pasa.** Todos los tests de ejemplo del motor usan redes con horarios distintos entre sí.
`RandomPlannerFixture` genera **una cadencia positiva fija por patrón**
(`BruteForceReference.swift:192`), así que no produce horas iguales, y sus footpaths son de 30 a
300 s (`:232`), así que no produce caminatas de 0 s. Los empates —el único sitio donde `<` y `<=`
difieren— **no están en el espacio de instancias que la suite explora**.

**Cómo lo arreglaría.** No es un arreglo de código: el código es correcto. Es cerrar el hueco de
verificación. Dos cosas, ambas baratas:

1. Ampliar `RandomPlannerFixture` para que a veces genere cadencia 0 (viajes con horas idénticas),
   footpaths de 0 s y paradas gemelas. Mi generador ampliado lo hace y está en §7.
2. Comparar en `BruteForceReferenceTests` **también los `parent`**, no solo los valores, o al menos
   afirmar que dos ejecuciones sobre la misma instancia producen `parent` idénticos.

**Cómo lo verificaría.** Es el propio criterio: con (1) y (2), m01 y m02 deben ponerse en rojo.
Para m03, un test de ejemplo con dos viajes del mismo patrón a la misma hora afirmando qué
`tripID` sale.

---

### H-08 · El desplazamiento entre días por cambio de hora no tiene test

**TimetableBuilder.swift:73** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Qué pasa.** La línea

```swift
let offset = Int32(midnight.timeIntervalSince(anchorMidnight).rounded())
```

lleva tres líneas de comentario explicando que no es 86.400 fijo porque «dos veces al año las
medianoches consecutivas en Madrid están a 23 o 25 horas, y una hora de error caería justo sobre
las líneas nocturnas». **El código es correcto. La mutación m08, que lo sustituye por
`Int32(dayShift * 86_400)`, no la caza ningún test.**

**Instancia mínima.** Medido con el calendario de `Europe/Madrid`:

```
ancla 20260329: [+1: real 82800  ingenuo 86400   <-- DIFIERE en -3600 s]
ancla 20260330: [-1: real -82800 ingenuo -86400  <-- DIFIERE en +3600 s]
ancla 20261025: [+1: real 90000  ingenuo 86400   <-- DIFIERE en +3600 s]
ancla 20261026: [-1: real -90000 ingenuo -86400  <-- DIFIERE en -3600 s]
ancla 20260905: sin diferencia en ninguno de los tres desplazamientos
```

Cuatro días de anclaje al año en los que la versión ingenua desplaza **una hora entera** todos los
viajes del día vecino. Con la ventana de siete días del feed, eso es del orden de **cuatro de cada
365 días con todos los horarios nocturnos movidos 60 minutos**.

**Por qué pasa.** Todas las fechas de los fixtures (`Fixture`, `PlannerFixture`,
`RandomPlannerFixture`) son de enero o de septiembre. Nunca se construye un `Timetable` anclado en
el 29/30 de marzo ni en el 25/26 de octubre, así que la diferencia nunca se materializa.

Conviene decir lo que **sí** está bien y no debe leerse como en peligro: el eje temporal en sí es
sólido. Verifiqué contra el feed real que el plegado de tres días es correcto en los dos bordes de
la ventana (§H-10, medición D4) y que dos construcciones del mismo feed dan arrays **byte a byte
idénticos** en las siete matrices.

**Cómo lo arreglaría.** Un test, no un cambio de código. En `TimetableBuilderTests.swift`:
construir un feed sintético con un viaje a las `25:10` anclado en `20261025` y en `20260329`, y
afirmar el instante absoluto resultante. Alternativa aún más barata y casi igual de buena: un test
unitario sobre la aritmética sola, exactamente la tabla de arriba, que no necesita ni base de datos
ni GTFS.

**Cómo lo verificaría.** Ese test debe tumbar m08 (`offset = Int32(dayShift * 86_400)`). Hoy no lo
tumba nada.

---

### H-09 · La cláusula de `departures` en `overtakes` no tiene test

**TimetableBuilder.swift:301** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** testabilidad

**Qué pasa.** `overtakes` comprueba adelantamiento sobre las llegadas **y** sobre las salidas:

```swift
if candidate.arrivals[position] < reference.arrivals[position] { return true }
if candidate.departures[position] < reference.departures[position] { return true }   // m09
```

La segunda línea es la que protege la precondición de `RaptorEngine.earliestTrip`, que busca
binariamente sobre **`departure`**. Borrarla (m09) **no pone en rojo ningún test**.

**Instancia mínima.** No es explotable hoy, y conviene decirlo con precisión: comprobé el feed real
y tiene **cero tiempo de parada** — `arrival == departure` en las **137.456** filas de
`stop_times.txt`, dwell máximo 0 s. Sin dwell, las dos cláusulas son la misma comprobación y m09 es
literalmente inocua. El riesgo es futuro: en cuanto un feed traiga dwell, o entre el ferry de la
Fase 2 (donde una espera en el muelle es lo normal), un viaje que llegue después pero salga antes
dejaría de separarse y las **dos** búsquedas binarias devolverían basura en silencio. Mi contraste
midió qué significa eso: **174 discrepancias** contra la referencia en cuanto la precondición se
rompe.

**Por qué pasa.** Todos los fixtures del proyecto ponen `arrival == departure`, igual que el feed.
La rama nunca se ejerce con valores distintos.

**Cómo lo arreglaría.** Test en `TimetableBuilderTests.swift` con dos viajes de un patrón donde
`X` llega antes que `Y` en una parada pero sale después (dwell largo), afirmando que acaban en
**patrones distintos**. Lo comprobé a mano con la función real y hace lo correcto:

```
G2 arr/dep discrepantes -> grupos = [[0], [1]]      (los separa, correcto)
G2 viajes idénticos     -> grupos = [[0, 1]]        (no los separa, correcto)
```

**Cómo lo verificaría.** Ese test debe tumbar m09. Y como red general, la propiedad que fuzzeé:
para todo patrón construido, los viajes son puntualmente no decrecientes en llegada **y** en
salida en todas las posiciones — 20.000 instancias, 36.013 grupos, 0 violaciones. Merece la pena
tenerla en la suite: es una invariante de una línea que cubre toda la clase.

---

### H-10 · No se relajan footpaths en la ronda 0, y la poda global remata la pérdida

**RaptorEngine.swift:103-117** · **Severidad:** baja · **Confianza:** media ·
**Categoría:** optimalidad

**Qué pasa.** La ronda 0 no relaja footpaths, por una razón escrita y buena («el radio de acceso ya
es la capa peatonal, y encadenar permitiría caminatas de radio + 300 m»). El efecto de segundo
orden no está escrito: una parada X alcanzada a pie en la ronda 0 fija `bestArrival[X]`, lo que
**impide** que un autobús que llegue a X más tarde escriba etiqueta en la ronda 1 — y con ella se
pierde la relajación de los footpaths que salen de X, que la ronda 0 tampoco hizo. La parada
vecina de X queda inalcanzable por las dos vías a la vez.

**Instancia mínima.** Encontrada por el oráculo y volcada entera:

```
acceso  = [s1+263s, s2+79s, s3+204s]      salida = [s2+667s, s0+509s, s3+839s]
footpaths: s1->s0 0s, s2->s0 0s, s3->s0 0s, s2<->s3 96s
patrón 0 [L0] paradas [3, 1, 0, 2]  viaje 0: [1650, 1899, 1986, 2205]

etiquetas ronda 0: [-, 1642, 1458, 1583]
etiquetas ronda 1: [1986, -, -, -]

óptimo del oráculo: coger L0 en s3, bajar en s1 a 1899, andar 0 s a s0, 509 s a la puerta = 2408
lo ofrecido:        coger L0 en s3, seguir hasta s0 a 1986,             509 s a la puerta = 2495
```

La bajada en s1 a las 1899 no se escribe porque `bestArrival[s1] = 1642` (la caminata de acceso de
la ronda 0), y desde s1 nunca se relaja el footpath de 0 s a s0.

**Alcance real, dicho con honestidad.** En el oráculo son 46 de 973 instancias (4,7 %). **Creo que
la mayoría no son alcanzables con el planificador real**, y la razón es concreta: en el motor de
verdad, acceso y salida salen de `nearbyStops` sobre un radio de 800 m, así que una parada a 0
segundos a pie de una parada de acceso está casi siempre **también** en la lista de acceso, y se
alcanza directamente en la ronda 0. Mi generador crea los footpaths con independencia del conjunto
de acceso, cosa que la geometría real no hace. Lo reporto con **confianza media** y como
consecuencia documentada de una política deliberada, no como un error de programación.

**Cómo lo arreglaría.** Probablemente **nada**, y esa es una respuesta legítima. Si se quisiera
cerrar, la vía barata y coherente con el diseño no es tocar el motor sino el resolutor: incluir en
`access` los vecinos por footpath de las paradas de acceso, con el coste ya sumado, de modo que la
capa peatonal siga siendo de un salto pero completa. La vía cara —relajar footpaths en la ronda 0—
es justo la que el comentario descarta, y con razón.

**Cómo lo verificaría.** Si se decide no hacer nada: **escribirlo en el comentario de `:105-106`**,
que hoy explica la mitad de la decisión (por qué no se encadena) pero no la otra mitad (que a
cambio se pierden bajadas junto a paradas de acceso). Un comentario que declara una precondición es
el criterio con el que se juzga el código; este declara media.

---

### H-11 · `nearbyStops` corta a 40 en silencio, y en Vigo el tope se alcanza

**TransitRepository.swift:161-186** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** corrección

**Qué pasa.** `nearbyStops` tiene `limit: Int = 40` y `JourneyPlanner` la llama sin pasar nada, así
que **acceso y salida están capados a 40 paradas cada uno**, recortando por distancia. No es
hipotético: contra el feed real, en Praza de América y en los otros siete puntos que probé, el
resultado es **exactamente 40 en ambos extremos** — el tope está activo en el centro de Vigo, no
cerca.

```
H1 paradas de acceso 40, de salida 40 (límite 40)
```

Para el acceso el recorte es benigno (se quedan las más cercanas). Para la **salida** interactúa
mal con la Fase 10: el conjunto del que sale el frente de Pareto de bajada está preseleccionado por
distancia, que es una de las dos dimensiones de ese frente. Una parada a 780 m que el autobús
alcanza muchísimo antes puede quedar fuera por ser la 41.ª más cercana.

**Instancia mínima.** No la construí para el planificador completo; el hecho medido es que el tope
está saturado en el feed real, y el razonamiento sobre su efecto en el frente es análisis, no
observación. Lo marco como tal.

**Por qué pasa.** El valor por defecto se escribió para el buscador de paradas cercanas, donde 40
es una lista razonable para una pantalla. El planificador lo hereda sin decidirlo: `JourneyPlanner.swift:67`
y `:73` pasan `radiusMetres` y nada más.

**Cómo lo arreglaría.** Pasar un límite explícito desde `PlannerOptions` en las dos llamadas del
planificador, con un valor pensado para esto (o `Int.max`, ya que el radio es la cota real y 800 m
en Vigo da del orden de 40–60 paradas). Como mínimo, que el número sea una decisión escrita en
`PlannerOptions` junto a los otros trece, y no un valor por defecto heredado de otra pantalla.

**Cómo lo verificaría.** Test en `JourneyPlannerTests` con 45 paradas dentro del radio y la mejor
salida en la posición 42.ª por distancia: hoy no se ofrece. Mutación que debe tumbarlo: volver al
límite implícito de 40.

---

### H-12 · `TimetableBuilder.build` bloquea un hilo cooperativo ~108 ms

**TimetableStore.swift:44** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** concurrencia

**Qué pasa.** `TimetableStore` es un actor y `timetable(anchor:)` llama a `TimetableBuilder.build`
de forma **síncrona**, que a su vez hace lecturas bloqueantes de SQLite. Medido contra el feed real:
**108,6 ms** de hilo del pool cooperativo bloqueado, más la lectura de `feedStatus()` de antes.

El comentario del fichero (`:8-12`) razona bien sobre la **corrección** —no hay punto de suspensión
dentro, así que el aislamiento del actor ya serializa y no hace falta el `inFlight` que sí necesita
`ThrottledRealtimeProvider`— y ese razonamiento **lo comprobé y es cierto**. Lo que no menciona es
que bloquear un hilo del pool cooperativo es lo que Swift 6 desaconseja: el pool tiene tantos hilos
como núcleos y no crea más cuando uno se bloquea.

**Instancia mínima.** La medición de arriba. No construí un caso de inanición real; con una sola
construcción ocasional y 8–10 núcleos, el riesgo práctico en esta app es bajo, y lo digo como tal.

**Por qué pasa.** GRDB `read` es bloqueante y el actor no tiene forma de ceder el hilo mientras
dura.

**Cómo lo arreglaría.** El cambio mínimo es no hacer nada y **anotarlo** en el comentario, que hoy
argumenta la corrección y calla el coste. Si algún día molesta, la forma habitual es sacar la
construcción a un hilo propio (`DispatchQueue` dedicada con un `withCheckedContinuation`, o el
`async` de GRDB) y mantener el actor solo para la caché.

**Cómo lo verificaría.** No es automatizable de forma barata. La medición de `H1` (108,6 ms) es el
número a vigilar; si el feed creciera y se acercara a los centenares de ms, el argumento cambia.

---

### H-13 · El constructor no verifica sus propias precondiciones sobre los tiempos

**TimetableBuilder.swift:245-263** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** deuda

**Qué pasa.** El barrido hacia delante de RAPTOR supone que los tiempos de un viaje son no
decrecientes a lo largo de sus posiciones, y que `ORDER BY st.stopSequence` da el orden real del
viaje. Ninguna de las dos cosas se comprueba al leer. Si un feed trajera una secuencia no monótona
o un tiempo que retrocede, el motor no fallaría: devolvería trayectos plausibles y equivocados, que
es el modo de fallo que este proyecto declara querer evitar por encima de todo.

`DATA-SOURCES.md` documenta que el feed actual tiene **0 secuencias no monótonas y 0 horas
malformadas**, y lo confirmé (0 dwell, 137.456 filas). Así que hoy la precondición se cumple —por
la propiedad del dato, no por una comprobación del código.

**Instancia mínima.** No construida: exigiría un feed corrupto, y el importador ya rechaza varias
formas de corrupción.

**Por qué pasa.** La validación estructural vive en `GTFSValidator`, en el camino de importación;
`TimetableBuilder` lee de la base de datos ya importada y confía. Es una decisión razonable, solo
que no está escrita como tal en el sitio donde importa.

**Cómo lo arreglaría.** En `flush()` (`:210-233`), donde ya hay dos guardas de sanidad (`stops.count >= 2`,
`usable`), añadir una tercera: descartar el viaje si `departures`/`arrivals` no son no decrecientes.
Es una pasada lineal sobre datos que ya están en la mano, del orden de microsegundos sobre 190.000
filas, y convierte un fallo silencioso en un viaje ausente. El comentario de `:256-258` ya usa
exactamente ese argumento para otra guarda: «medio viaje es peor que ninguno».

**Cómo lo verificaría.** Test en `TimetableBuilderTests` con un `stop_times` que retroceda en el
tiempo dentro de un viaje: ese viaje no aparece en ningún patrón. Mutación: quitar la guarda.

---

### H-14 · `?? ride.trip` del ajuste hacia atrás es código muerto

**JourneyReconstruction.swift:240-241** · **Severidad:** nit · **Confianza:** alta ·
**Categoría:** deuda

**Qué pasa.** El encargo pregunta si el `?? ride.trip` de reserva es alcanzable. **No lo es.**

**Por qué.** `latestTrip` devuelve `nil` solo si el viaje 0 del patrón llega después de `limit`.
Para el último tramo, `limit` **es** la llegada de su propio viaje, que por tanto satisface el
predicado. Para un tramo anterior, `limit = boardTime(i+1) − holgura`, y la factibilidad que RAPTOR
ya estableció garantiza `arrival_i + holgura <= boardTime(i+1)` en los tres tipos de hueco
(`.sameStop` con `minTransferSeconds`, `.walk` con `footpathBufferSeconds + segundos`, `.access`
que no propaga). Luego `arrival_i <= limit` siempre, y siempre existe al menos un viaje válido.
Como corolario, el viaje elegido nunca es anterior al original, así que **el ajuste jamás vuelve
infactible el tramo previo** — la otra pregunta del encargo, y la respuesta es que está bien.

Confirmado empíricamente: sobre 973 instancias con oráculo estricto (misma cadena, misma parada de
bajada, misma hora de llegada), el ajuste hacia atrás produce **la salida más tardía posible en el
100 % de los casos**, 0 fallos.

**Cómo lo arreglaría.** Sustituir el `??` por algo que diga lo que se sabe:

```swift
guard let latest = latestTrip(...) else {
    assertionFailure("el viaje original ya cumple el límite, así que esto no puede pasar")
    return nil
}
```

Un `??` silencioso convierte una imposibilidad demostrable en una rama que nadie volverá a mirar.

**Cómo lo verificaría.** No es testeable por definición (es código inalcanzable). El valor está en
que el comentario de `:308-311`, que ya explica por qué la búsqueda binaria es sólida, diga también
por qué nunca devuelve `nil` aquí.

---

### H-15 · `TimetableStore.invalidateAll()` no lo llama nadie

**TimetableStore.swift:56-59** · **Severidad:** nit · **Confianza:** alta · **Categoría:** deuda

**Qué pasa.** Buscado en todo el repositorio (`App/`, `VigoCore/Sources`, `VigoCore/Tests`): el
único resultado es la propia declaración. Es código muerto, y además sin test.

El comentario dice que la huella del feed en la clave ya impide servir una instantánea rancia —
cierto y verificado— y que esto es «solo para liberar memoria». Como no se llama, esa memoria no se
libera: tras un refresco del feed la caché LRU conserva hasta **3 instantáneas obsoletas** (del
orden de 0,6 MB cada una, medido: 188 patrones, 1.892 viajes, 70.679 tiempos) hasta que tres
consultas nuevas las desalojen.

**Cómo lo arreglaría.** O llamarlo desde donde el feed se reimporta (`GTFSFeedService` /
`AppEnvironment.refreshFeed`), que es lo que su comentario da a entender que pasa; o borrarlo. Las
dos son defendibles; dejarlo como está es la única que no lo es.

**Cómo lo verificaría.** Si se llama: test en `TimetableStoreTests` que reimporte y compruebe que
la caché queda vacía. Si se borra: nada.

---

### H-16 · Los `&+`/`&-` son seguros por construcción, pero nada lo dice ni lo comprueba

**RaptorEngine.swift**, **JourneyReconstruction.swift** · **Severidad:** nit ·
**Confianza:** alta · **Categoría:** aritmética

**Qué pasa.** El encargo pide dictaminar cada uso. Lo hice; el resultado es que **no encontré
ningún desbordamiento alcanzable**, pero tampoco ninguna línea que lo documente ni ninguna
aserción que lo defienda.

| Uso | ¿Desborda? | Por qué |
|---|---|---|
| `query.departure &+ query.horizon` (`:101`) | No | Eje acotado a ±2 días (±172.800) más horizonte de 10.800 |
| `query.departure &+ entry.seconds` (`:110`) | No | Caminata de acceso ≤ 800 m ≈ 812 s |
| `arrives &+ minTransfer` (`:162`) | No | `arrives` es un valor real del horario, ≤ 186.540 medido |
| `from &+ seconds` (`:211`) | No | Ídem, footpath ≤ 300 m |
| `reached &+ exit.seconds` (`:243`) | No | `reached != unreached` está guardado en `:242` |
| `boardTime &- minTransfer` / `&- buffer &- seconds` (`:249, :251`) | No | Restas sobre horas reales |
| `networkArrival &+ egressSeconds` (`:304`) | No | Ídem |
| `candidate.round &* 1_000_003 &+ candidate.stop` (`:85`) | No | Ver H-17 |
| `value &+ exit.seconds` (`egressCandidates:126`) | No | `result.arrival(...)` devuelve `nil` si es `unreached` |

El caso que el encargo señala —`RaptorResult.unreached == Int32.max` participando en sumas— **está
guardado en los tres sitios donde podría ocurrir**. Eso está bien y merece decirse.

Lo que sí es frágil son las conversiones **atrapantes** (no envolventes) que rodean al motor:
`Int32(row["arrival"] as Int)` en `TimetableBuilder.swift:261-262`, `Int32(options.searchHorizon)` y
`Int32(timetable.axisSeconds(for:))` en `JourneyPlanner.swift:148-149`. Ninguna es alcanzable hoy
—`plan` comprueba la ventana del feed antes, así que el eje está acotado— pero una de ellas es un
`crash`, no un valor raro, si esa comprobación se moviera de sitio.

**Cómo lo arreglaría.** Una línea en `Timetable` que declare la cota del eje («segundos en
[−2 días, +3 días] respecto a la medianoche del ancla; de ahí que todo el motor use `Int32` y
operadores envolventes sin riesgo»), y un `assert` en `JourneyPlanner.scan` de que
`axisSeconds` cae en esa cota. Es documentación con dientes, no defensa contra lo imposible.

**Cómo lo verificaría.** No hace falta test: la afirmación es sobre el rango de los datos, y el
`assert` la comprueba en cada ejecución de la suite.

---

### H-17 · `exitKey` es un hash a mano que colisiona por encima de 10⁶ paradas

**JourneyReconstruction.swift:84-86** · **Severidad:** nit · **Confianza:** alta ·
**Categoría:** deuda

**Qué pasa.** `candidate.round &* 1_000_003 &+ candidate.stop` se usa como **identidad**, no como
hash: `seenExits` decide con él si un candidato ya se reconstruyó. Con 1.154 paradas y 4 rondas no
hay colisión posible, así que hoy es correcto. Pero es un `Int` que finge ser una tupla, y si
`stopCount` superase 1.000.003 dos candidatos distintos se leerían como el mismo y una alternativa
desaparecería en silencio.

**Cómo lo arreglaría.** `Set<EgressCandidate>` con `Hashable` sintetizado sobre `(round, stop)`, o
un `Set<[Int]>`. El coste es nulo (decenas de elementos) y el fallo por construcción desaparece.

**Cómo lo verificaría.** No es testeable a esta escala; es una simplificación que quita una
suposición, no un arreglo.

---

### H-18 · Ordenaciones no estables en empates de tres sitios

**JourneyReconstruction.swift:139 y 78**, **TransitRepository.swift:179** ·
**Severidad:** nit · **Confianza:** media · **Categoría:** determinismo

**Qué pasa.** Tres ordenaciones desempatan por un solo campo y `sorted(by:)` de Swift **no es
estable**:

- `egressCandidates:139` — `front.sorted { $0.arrival < $1.arrival }`, y luego `trim` elige por
  posición. Dos paradas gemelas con la misma llegada y la misma caminata (el caso «paradas
  gemelas» que el encargo pide probar) dejan el orden sin especificar.
- `alternatives:78` — `sorted { $0.arrival < $1.arrival }` antes del `prefix`.
- `nearbyStops:179` — `sorted { $0.1 < $1.1 }` antes del `prefix(limit)`.

La invariante 7 pide que «dos ejecuciones produzcan resultados idénticos».

**Instancia mínima.** Construí el caso —tres salidas empatadas en llegada **y** en caminata, con
`trim(limit: 2)`— y **no observé no determinismo**: 50 ejecuciones, una sola salida (`1,3`). El
`sorted` de Swift es determinista para una entrada dada aunque no sea estable, así que el riesgo es
contractual, no observado. Lo reporto con confianza media y severidad nit precisamente por eso.

**Cómo lo arreglaría.** Añadir el índice de parada como último desempate en las tres. Una palabra
por sitio, y la invariante deja de depender de un detalle no documentado de la biblioteca estándar.

**Cómo lo verificaría.** El propio test de arriba, afirmando la salida exacta. No tumbaría nada hoy;
su valor es fijar el contrato.

---

### H-19 · `walkOnly` esconde todos los autobuses, incluso bajo «menos caminata»

**JourneyPlanner.swift:128-131** · **Severidad:** nit · **Confianza:** alta ·
**Categoría:** corrección

**Qué pasa.** Si la caminata directa llega antes que el mejor autobús, el resultado es
`.walkOnly(journey)` y **las alternativas en bus se descartan enteras**. Bajo `earliestArrival` es
coherente. Bajo el criterio **por defecto** no lo es: un trayecto solo a pie tiene, por definición
de `JourneyOrdering.egressWalkSeconds`, la caminata final más larga posible (el trayecto entero),
así que es el peor bajo «Menos caminata» — y es el único que se ofrece.

**Instancia mínima.** No construida; se sigue de leer `:128-131` junto a `egressWalkSeconds:95-98`,
y lo marco como análisis.

**Cómo lo arreglaría.** Es una decisión de producto más que un bug. La opción coherente con la
Fase 10 es devolver `.journeys` con el trayecto a pie **incluido en la lista** cuando además hay
autobuses, y reservar `.walkOnly` para cuando no hay ninguno. `JourneyOrdering.earliestBoarding` ya
tiene escrito cómo ordenar un trayecto sin embarque (va al final), así que la maquinaria existe.

**Cómo lo verificaría.** Test en `JourneyPlannerTests`: con caminata directa más rápida y un
autobús disponible, el resultado contiene ambos. Mutación: volver a descartar los autobuses.

---

## 5. Resultados de la mutación

19 mutaciones, cada una aplicada sola sobre una copia intacta, `swift test` completo (321 tests) y
reversión. **5 sobreviven.**

| # | Fichero | Mutación | Tests rojos | Veredicto |
|---|---|---|---|---|
| m01 | RaptorEngine:159 | mejora en bus `<` → `<=` | **0** | **SOBREVIVE** — H-07 |
| m02 | RaptorEngine:212 | mejora a pie `<` → `<=` | **0** | **SOBREVIVE** — H-07, y habilita el cuelgue de H-06 |
| m03 | RaptorEngine:179 | `current > boardable` → `>=` | **0** | **SOBREVIVE** — H-07 |
| m04 | RaptorEngine:174 | embarcar con la ronda actual | 14 | Cazada a fondo |
| m05 | RaptorEngine:202 | quitar la foto `rideArrival` | 3 | Cazada **solo** por el contraste aleatorizado |
| m06 | RaptorEngine:262 | `earliestTrip` `>=` → `>` | 7 | Cazada |
| m07 | TimetableBuilder:117 | sin separación por adelantamiento | 18 | Cazada a fondo |
| m08 | TimetableBuilder:73 | desplazamiento fijo de 86.400 | **0** | **SOBREVIVE** — H-08 |
| m09 | TimetableBuilder:301 | `overtakes` ignora las salidas | **0** | **SOBREVIVE** — H-09 |
| m10 | JourneyReconstruction:240 | ajuste hacia atrás desactivado | 5 | Cazada |
| m11 | JourneyReconstruction:148 | `trim` solo por la cabeza | 3 | Cazada |
| m12 | JourneyReconstruction:139 | una sola bajada (pre-Fase 10) | 5 | Cazada |
| m13 | JourneyReconstruction:79 | cortar por `maxAlternatives` | 3 | Cazada |
| m14 | JourneyShortlist:32 | dominancia sin el eje de caminata | 4 | Cazada |
| m15 | JourneyShortlist:54 | cortar por llegada en vez de rotar | 4 | Cazada |
| m17 | JourneyOrdering:57 | `leastWalkAtEnd` como duración | 9 | Cazada |
| m18 | JourneyOrdering:66 | `earliestBoarding` sobre `departure` | 4 | Cazada |
| m19 | JourneyOrdering:86 | desempate de `earliestArrival` invertido | 3 | Cazada |
| m20 | JourneyOrdering:49 | `apply` corta antes de ordenar | 8 | Cazada |
| m21 | JourneyOrdering:96 | `egressWalkSeconds` = última caminata entre paradas | 10 | Cazada |

*(Una vigésima mutación, cambiar el eje `departure` de la dominancia por `firstBoarding`, resultó ser
un no-op sintáctico y se excluyó; el hallazgo que perseguía es H-05, demostrado con instancia
propia.)*

**Veredicto por zona.**

- **Fase 10 (m11–m15, m17–m21): impecable.** Nueve mutaciones, nueve cazadas, varias por tests con
  nombre propio que describen exactamente la mutación. La verificación por mutación que
  `ESTADO.md` documenta («verificado por mutación, quince veces») **se sostiene**, y es lo mejor
  verificado del motor.
- **Constructor (m07): bien cubierto** en lo que respecta al adelantamiento; **descubierto** en el
  calendario (m08) y en la mitad de `overtakes` (m09).
- **Motor (m01–m06): cubierto donde los valores cambian, ciego donde no.** Las tres mutaciones que
  sobreviven son las tres que preservan las horas y cambian los punteros — que es, exactamente, la
  familia a la que pertenece H-02, el peor hallazgo de esta auditoría. No es coincidencia: es la
  misma sombra.
- **m05 merece una nota.** Solo la caza `BruteForceReferenceTests`, ningún test de ejemplo. Es la
  confirmación independiente de lo que el paso 4/11 de la Fase 3 dice: sin el contraste
  aleatorizado ese bug no tenía quien lo detectara. La herramienta funciona; su punto ciego es que
  compara valores y no trayectos.

---

## 6. Mapa del motor

Recorrido real de una consulta, con cada estructura, cada recorte y cada decisión irreversible.

```
PlanQuery(origin, destination, departure)
  │
  ▼ JourneyPlanner.plan                                       [no aislado; llamable desde @MainActor]
  ├─ repository.feedStatus()                    → .noData si no hay nada importado
  ├─ nearbyStops(origen, 800 m)                 → .noStopsNearOrigin        ⟵ RECORTE: limit 40 (H-11)
  ├─ nearbyStops(destino, 800 m)                → .noStopsNearDestination   ⟵ RECORTE: limit 40 (H-11)
  ├─ ServiceDate(departure) ∈ ventana del feed  → .outsideFeedWindow    ⟵ «no tengo datos»
  ├─ activeServiceIDs(day) no vacío             → .noServiceOnDay       ⟵ «no hay servicio»
  │      (el orden importa y es correcto: los dos hechos nunca se confunden — invariante 9)
  │
  ▼ TimetableStore.timetable(anchor: day)                                  [actor, LRU 3]
  │    clave (día, feedStatus.importedAt); en fallo de caché:
  │    TimetableBuilder.build — 108,6 ms medidos, bloqueantes sobre el ejecutor (H-12)
  │      ├─ allStops() ordenadas por id            → espacio compacto de índices
  │      ├─ para dayShift ∈ {−1, 0, +1}:
  │      │    offset = medianoche(día) − medianoche(ancla)   ⟵ real, no 86400 (correcto; sin test, H-08)
  │      │    activeServiceIDs(día); si vacío, el día NO entra en coveredDays
  │      │    trips(): cursor sobre stopTime ⨝ trip ORDER BY tripID, stopSequence
  │      │      guardas: ≥ 2 paradas, stopID conocido, y para ayer max(t) ≥ 86400
  │      │      NO se verifica monotonía de los tiempos (H-13)
  │      ├─ agrupar por PatternKey(routeID, secuencia de paradas)
  │      ├─ ordenar los viajes por departures[0], desempate por tripID     ⟵ DETERMINISMO
  │      ├─ nonOvertakingGroups: first-fit contra el último del grupo      ⟵ PRECONDICIÓN de las
  │      │      (fuzzeado: 20.000 instancias, 36.013 grupos, 0 violaciones)    dos búsquedas binarias
  │      ├─ incidencia inversa: (patrón, posición) por parada
  │      └─ WalkModel.footpaths: barrido en latitud, radio 300 m, simétrico
  │    → Timetable: arrays CSR Int32, 0,6 MB, byte a byte reproducible (verificado)
  │
  ▼ Task.detached(.userInitiated) { scan(...) }              [saca las 4 pasadas del hilo principal]
  │
  ▼ JourneyPlanner.scan — hasta maxDepartureScans = 4 pasadas
  │  ┌── por pasada ────────────────────────────────────────────────────────────────────┐
  │  │ RaptorQuery(access, egress, departure, horizon = deadline − departure)           │
  │  │                                                                                  │
  │  │ RaptorEngine.run — 3,89 ms medidos                                               │
  │  │   targetBest ← departure + horizon                                               │
  │  │   ronda 0: caminatas de acceso; footpaths NO relajados (política; H-10)          │
  │  │   targetBest ← min(targetBest, bestEgress)          ⟵ PODA, puerta a puerta      │
  │  │   por ronda 1…4:                                                                 │
  │  │     1. cola de patrones desde la posición marcada más temprana, orden por índice │
  │  │     2. barrido hacia delante:                                                    │
  │  │          bajar  si arrives < min(bestArrival[s], targetBest)   ⟵ PODA (H-03)     │
  │  │          subir  con ready[ronda−1][s]  ⟵ solo la etiqueta anterior (invariante 6)│
  │  │          saltar a un viaje anterior por búsqueda binaria (earliestTrip)          │
  │  │     3. un salto a pie desde las paradas bajadas, con la foto rideArrival         │
  │  │          ⚠ el VALOR está fotografiado; el PARENT no  ⟵ H-02                      │
  │  │     4. targetBest ← min(targetBest, bestEgress)     ⟵ PODA que aprieta (H-03)    │
  │  │   → RaptorResult(arrival, parent, bestArrival) — etiquetas verificadas correctas │
  │  │                                                                                  │
  │  │ JourneyReconstruction.alternatives — 0,06 ms medidos                             │
  │  │   por ronda 1…roundsRun:                                                         │
  │  │     egressCandidates: frente de Pareto (llegada, caminata final)                 │
  │  │        trim por los DOS extremos            ⟵ RECORTE: maxEgressCandidates = 3   │
  │  │        (correcto: conserva ambos óptimos; m11 lo confirma)                       │
  │  │     la primera → byTransfersAscending (filtro extraTransferWorthSeconds)         │
  │  │     el resto  → closerOnFoot (sin ese filtro, a propósito)                       │
  │  │   reconstruct por candidata:                                                     │
  │  │     seguir los parent hacia atrás  ⟵ H-02 (encadena), H-06 (sin cota)            │
  │  │     ajuste hacia atrás: viaje más tardío por tramo   ⟵ VERIFICADO ÓPTIMO (0/973) │
  │  │     montar tramos hacia delante                                                  │
  │  │     Journey.arrival = última llegada en bus + caminata de salida   ⟵ H-01        │
  │  │   (kept + closerOnFoot).sorted(por llegada).prefix(8)  ⟵ RECORTE POR LLEGADA H-04│
  │  └──────────────────────────────────────────────────────────────────────────────────┘
  │  siguiente pasada desde min(primer embarque del lote) + 1  ⟵ garantiza un bus posterior
  │  corta si ranked(collected).count ≥ 8 o si se pasa del horizonte
  │
  ▼ JourneyPlanner.ranked
  │   deduplicar con Set<Journey>                       (hash 3,86 µs; irrelevante a esta escala)
  │   JourneyShortlist.undominated — 4 ejes: departure↑, arrival↓, transfers↓, caminata final↓
  │        ⟵ DECISIÓN IRREVERSIBLE: aquí desaparecen alternativas para siempre.
  │        ⟵ el eje `departure` no es el `earliestBoarding` del menú (H-05)
  │   JourneyShortlist.cut(a 8) — rotación entre los tres criterios   ⟵ RECORTE SIN SESGO ✔
  │
  ▼ .journeys([Journey])  |  .walkOnly  |  .noJourneyFound
  │   walkOnly gana si la caminata directa ≤ horizonte Y llega antes que el mejor bus (H-19)
  │
  ▼ MapNavigationState.planningFinished → route = .alternatives(journeys)
  ▼ visibleJourneys = ordering.apply(route.journeys, limit: 4)
        ordena PRIMERO, corta DESPUÉS   ⟵ correcto, y con test propio (m20 lo confirma)
        setOrdering resetea selectedAlternative e isFollowing  ⟵ correcto
  ▼ FirstBoardingMatch: anota el primer embarque con tiempo real. NUNCA decide. ✔
```

**Dónde se decide de forma irreversible, en orden:** el límite de 40 de `nearbyStops`; la poda por
`targetBest` dentro del motor (H-03); el `trim` del frente de bajada; el `prefix(8)` por llegada de
`alternatives` (H-04); `undominated` (H-05); `cut`; y el `prefix(4)` de `visibleJourneys`. De los
siete, **tres aplican un criterio de llegada antes de que exista una preferencia**, y solo uno de
esos tres —el de `visibleJourneys`— está donde la Fase 10 lo puso.

---

## 7. Lo que está bien

No es una sección de cortesía. Estas decisiones aguantaron el escrutinio y varias las verifiqué a
propósito para ver si caían.

1. **`nonOvertakingGroups` es correcto, y su argumento también.** El comentario afirma que
   «comparar contra el último del grupo basta porque el grupo se construye en orden no
   decreciente». Lo verifiqué como el argumento matemático que es —el último es el máximo puntual
   por inducción, luego dominarlo domina a todos— y lo fuzzeé: **20.000 instancias, 36.013 grupos,
   0 violaciones**, incluidos viajes con horas idénticas (van al mismo grupo, correcto) y con
   llegada y salida discrepantes (se separan, conservador y correcto). Un `first-fit` no deja
   grupos con un miembro que adelante a otro no adyacente. **No lo toque nadie sin rehacer este
   fuzz.**

2. **La precondición de las búsquedas binarias es real y está bien colocada.** Mi contraste
   ampliado da **0 discrepancias en 20.000 instancias** cuando se cumple y **174** cuando la rompo
   a propósito. Eso no es un test que pasa: es la demostración de que la separación por
   adelantamiento es lo único que sostiene la corrección del motor, exactamente donde el
   comentario de `TimetableBuilder:274-279` dice que está.

3. **El ajuste hacia atrás es óptimo, no aproximado.** Contra el oráculo estricto —misma cadena,
   misma parada de bajada, misma hora de llegada— produce la salida más tardía posible en el
   **100 % de 973 instancias**. Y el `?? ride.trip` es inalcanzable porque la factibilidad de
   RAPTOR ya garantiza que el viaje original cumple el límite (H-14). Es una pieza demostrablemente
   correcta.

4. **`trim` desde los dos extremos hace lo que promete.** Sobre un frente de Pareto ordenado por
   llegada, la cola es siempre el mínimo de caminata (si dos empatan en llegada, empatan también en
   caminata, o uno domina al otro), así que tomar alternadamente de los dos extremos conserva ambos
   óptimos **para cualquier `limit`**. La nota de `ESTADO.md` sobre que la mutación se escapó con un
   frente de dos miembros y hubo que reescribirlo con tres es la clase de honestidad que hace útil
   ese documento.

5. **`cut` por rotación garantiza de verdad lo que dice.** Cada criterio toma su mejor no elegido
   por turnos, así que los tres óptimos entran en las tres primeras posiciones sea cual sea el
   límite. Verificado por lectura y confirmado por m15.

6. **`visibleJourneys` ordena antes de cortar, y `setOrdering` resetea el índice y el seguimiento.**
   Las dos cosas que la Fase 10 identificó como «invariante en peligro» están bien hechas y con
   test que las fija (m20 tumba 8 tests).

7. **La distinción `outsideFeedWindow` / `noServiceOnDay` está bien hecha y bien colocada.**
   Comprobada contra el feed real en los dos bordes de la ventana: anclado en 20260905, ayer tiene
   0 servicios y `coveredDays` lo excluye; anclado en 20260911, mañana tiene 0 y el eje llega a
   30 h 20, que es justo lo que una consulta nocturna del último día necesita. El plegado de tres
   días cubre las 24:00 sin agujeros.

8. **La construcción es determinista byte a byte.** Verificado sobre el feed real: `patternStops`,
   `tripArrival`, `tripDeparture`, `tripRefs`, `footpathTarget`, `footpathSeconds` y
   `stopPatternPattern` idénticos entre dos construcciones. Los ordenamientos por id y los
   desempates por `tripID` están puestos a propósito y funcionan.

9. **El tiempo real anota y nunca decide.** `FirstBoardingMatch` no tiene ningún camino de vuelta
   al motor; `RaptorEngine` no importa nada de `Network/`. La invariante 2 se cumple
   estructuralmente, no por disciplina.

10. **El rendimiento no es un problema y no hay nada que microoptimizar.** Medido sobre el feed
    real: construcción en frío 108,6 ms, plan en caliente **21–22 ms** para cuatro pares reales
    cruzando la ciudad, una pasada de RAPTOR 3,89 ms, una reconstrucción 0,06 ms. Lo que temía el
    encargo —hashear `Journey` con sus `intermediateStops` dentro de un `Set`— son **3,86 µs** por
    hash sobre journeys de 13 paradas, con decenas de hashes por consulta: irrelevante frente a los
    3,89 ms del motor. `undominated` es O(n²) sobre n ≤ 8. **No escala mal nada.** El presupuesto
    de 1 s tiene 45× de margen.

11. **La verificación de la Fase 10 es la mejor del proyecto.** Nueve mutaciones dirigidas, nueve
    cazadas, con tests cuyos nombres describen la mutación que los tumba. Es el modelo a copiar en
    el motor, que es donde faltan.

---

## 8. Plan sugerido

Cuatro tandas, ordenadas por valor entregado y no por severidad.

### Tanda 1 — Las horas que se enseñan son falsas *(H-01, H-02, H-06)*

Las tres son el mismo tramo de código y se arreglan juntas en un cambio de unas veinte líneas. Es
el 90 % del valor de esta auditoría: afectan al **71,6 %** de las alternativas del feed real, la
peor por casi **18 minutos**, y producen trayectos que mandan andar 1,4 km presentándolo como un
transbordo.

- H-02: fotografiar `parent` junto a `rideArrival` y resolver `.walk(from:)` contra esa foto.
- H-01: sumar todas las caminatas posteriores al último bus en `Journey.arrival`.
- H-06: cota de `(roundsRun + 2) × stopCount` en el recorrido de `parent`.

**Para darla por buena:** la suite de 321 sigue verde (comprobado); las dos propiedades generales
nuevas en `JourneyReconstructionTests` —la llegada declarada es reconstruible desde los tramos, y
ninguna alternativa tiene dos `.walk` seguidos entre paradas— pasan sobre las redes existentes;
las dos instancias mínimas de H-01 y H-02 como tests con nombre; y la medición sobre el feed real
vuelve a dar **0 %** de caminatas encadenadas y 0 discrepancias de hora. Todo esto lo dejé
ejecutado y verde en la copia desechable, así que la tanda está esencialmente demostrada antes de
escribirse.

### Tanda 2 — El criterio por defecto elige de un conjunto que no lo contiene *(H-03, H-04, H-05)*

La Fase 10 hizo un trabajo cuidadoso y quedó rodeada por tres sitios que deshacen parte de él: la
poda del motor mata al candidato antes de que exista (H-03), el `prefix` por llegada lo tira si
existe (H-04) y la dominancia borra el óptimo de «Sale antes» (H-05). Ninguno se ve en pantalla:
solo devuelven peores respuestas.

- H-03: podar contra la llegada a la red, sin la caminata de salida. Medir el coste por pasada.
- H-04: sustituir el `prefix` por `JourneyShortlist.cut`, que ya existe y ya está probado.
- H-05: decidir entre cinco ejes o quitar `departure` de la dominancia. Recomiendo cinco.

**Para darla por buena:** las instancias mínimas de H-03 y H-05 como tests; el test de doce
candidatos de H-04; el óptimo de caminata deja de faltar en las 52 instancias del oráculo donde
hoy falta; el tiempo por pasada de RAPTOR sigue del orden de milisegundos sobre el feed real
(hoy 3,89 ms, presupuesto 1 s); y `EgressCandidatesTests` gana un caso **con transbordo**, que es
donde la poda muerde y donde la prueba actual no llega.

### Tanda 3 — Cerrar los cinco huecos de mutación *(H-07, H-08, H-09)*

Cinco mutaciones de un carácter que la suite no distingue del código correcto. Ninguna es un bug
hoy; las tres del motor son la misma sombra que dejó pasar H-02, así que cerrarlas es lo que
impide que vuelva.

- Ampliar `RandomPlannerFixture` con cadencia 0, footpaths de 0 s y paradas gemelas (mi generador
  ampliado hace esto y algo más; está descrito en §2 y puede portarse tal cual).
- Comparar también los `parent` en `BruteForceReferenceTests`, o al menos su reproducibilidad.
- Un test de calendario sobre el 25/10 y el 29/03, aunque sea solo sobre la aritmética.
- Un test de `overtakes` con dwell.

**Para darla por buena:** m01, m02, m03, m08 y m09 pasan a estar en rojo. Es un criterio binario y
comprobable: reaplicar las cinco mutaciones y ver caer la suite.

### Tanda 4 — Deuda y precisión *(H-10 a H-19)*

Nada urgente, todo barato, y varias cosas son solo escribir lo que ya se sabe.

- Límite explícito de `nearbyStops` en `PlannerOptions` (H-11), que es el único con efecto medible.
- Guarda de monotonía en `flush()` (H-13).
- Llamar o borrar `invalidateAll()` (H-15).
- Desempates por índice en las tres ordenaciones (H-18).
- `assert` de rango del eje y una línea de documentación sobre los `&+` (H-16); `?? ride.trip` a
  `assertionFailure` (H-14); `Set<EgressCandidate>` en vez del hash a mano (H-17).
- Completar dos comentarios que hoy declaran media precondición: el de la ronda 0 (H-10) y el de
  `TimetableStore` (H-12).
- Decidir qué hacer con `walkOnly` bajo «menos caminata» (H-19).

**Para darla por buena:** la suite sigue verde y los comentarios afectados describen lo que el
código hace. En un proyecto que documenta sus decisiones dentro del código, un comentario que
declara una precondición a medias es un hallazgo por derecho propio, y esta tanda es sobre todo eso.

---

## Anexo — Fuera de alcance

Dos cosas vistas de pasada, no auditadas, anotadas para que no se pierdan:

- `App/ILoveVigoRoutes/BackgroundRefresh.swift:42` usa `nonisolated(unsafe)` para capturar
  `processingTask`; es el único escape de aislamiento del proyecto y no lleva justificación escrita.
- `TransitRepository.nearbyStops` es la única lectura del planificador que pasa por
  `database.writer.read` sin índice espacial más allá de la caja de latitud/longitud; a 1.154
  paradas son 3,3 ms medidos, sin problema, pero es la consulta que más crecería con el feed.
