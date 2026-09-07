# Motor de rutas: el del Concello frente al nuestro

**Fecha:** 2026-09-07
**Objeto analizado:** `base.apk` de la app oficial **Vigo+** (`org.vigo.apps.vigoplus`)
**Método:** descompresión del APK, lectura de los *bundles* JavaScript, y **sondeo en vivo**
del servidor de planificación del Concello y del GTFS público.

> Todo lo que sigue está **observado**. Cada afirmación sobre el motor del Concello viene de
> una cadena literal del APK o de una respuesta HTTP que reproduje. Donde no pude verificar
> algo, lo digo.

---

## 1. Titular

**La app del Concello no calcula rutas.** Es un cliente HTTP delgado sobre una instancia de
**OpenTripPlanner** alojada por el Concello. Su motor "funciona perfecto" porque es OTP, un
planificador maduro con dos cosas que nosotros no tenemos: **un grafo de calles reales** y un
**calendario de 94 días**.

Y una corrección a la premisa de partida: **su planificador no combina bus + ferry**. Sólo
tiene autobús. Verificado abajo.

El diagnóstico de nuestro motor, en una frase: **el algoritmo es correcto; las entradas que le
damos no lo son.**

---

## 2. FASE 1 — El motor del Concello

### 2.1 Qué es la app

Híbrida **Cordova + Angular**. `assets/www/` con 662 *chunks* de JavaScript y
`org/apache/cordova/` en el `classes.dex`. No hay lógica de planificación en Java/Kotlin: está
toda en JS, y la que hay es de *presentación*.

### 2.2 El planificador es OpenTripPlanner

De `main.f6c6fb8dff62506e.js`, el objeto de entorno:

```js
otpUrl:       "https://planificador-rutas-api.vigo.org/v1/",
otpRoutesUrl: "https://planificador-rutas.vigo.org/otp/routers/default/plan"
```

`/otp/routers/default/plan` es la **API REST de OTP 1.x**, literal.

Sondeo en vivo de `/otp/routers/default` (respuesta real, 2026-09-07):

```json
{"routerId":"default","buildTime":1788652963273,
 "transitServiceStarts":1787176800,"transitServiceEnds":1795302000,
 "transitModes":["BUS"],
 "travelOptions":[{"value":"TRANSIT,WALK"},{"value":"BUS,WALK"},{"value":"WALK"},
                  {"value":"BICYCLE"},{"value":"CAR"},{"value":"TRANSIT,BICYCLE"},
                  {"value":"CAR_PARK,WALK,TRANSIT"},{"value":"CAR,WALK,TRANSIT"}],
 "hasCarPark":true,"hasParkRide":true}
```

- `travelOptions` con `PARKRIDE`/`KISSRIDE`, y los parámetros `optimize=TRIANGLE` y
  `maxWalkDistance` que envía el cliente, fijan la versión: **OTP 1.x** (RAPTOR entra en OTP 2).
- **Grafo construido el 2026-09-06.**
- **Ventana de servicio: 2026-08-19 → 2026-11-21. 94 días.**
- **`transitModes: ["BUS"]`.** No hay ferry, ni tren, ni bus interurbano.

### 2.3 Qué algoritmo es entonces

OTP 1.x resuelve con **A\* bidireccional sobre un grafo multimodal dependiente del tiempo**:
callejero peatonal de OSM + red de tránsito del GTFS, en un único grafo, con **coste
generalizado** (segundos "percibidos", no segundos reales). No es RAPTOR. No es Dijkstra puro.
Las alternativas (`numItineraries`) salen de búsquedas repetidas penalizando lo ya encontrado.

Lo relevante para nosotros no es el A\*: es que **el peatón se mueve por calles reales**.

### 2.4 La fuente de datos: la misma que la nuestra

```
GET /otp/routers/default/index/feeds   →  ["1"]
GET /otp/routers/default/index/routes  →  43 rutas, agencyName: "Viguesa de Transportes S.L."
```

Un solo feed. Vitrasa. **43 rutas con viajes** — exactamente las 59 de `routes.txt` menos las
16 sin viajes que ya documentamos en `DATA-SOURCES.md` §2.6. Es **nuestro mismo GTFS**.

No tienen datos que nosotros no tengamos. Tienen el mismo dato, mejor tratado.

### 2.5 Qué envía exactamente el cliente

De `23172.028ce2b9e788c171.js`, el servicio OTP:

```js
routeRequest(d, h, _, L) {
  let R = new HttpParams()
    .set("fromPlace", d.fromPlace).set("toPlace", d.toPlace)
    .set("arriveBy", d.arriveBy.toString())
    .set("date", d.date).set("time", d.time).set("locale", L)
    .set("showIntermediateStops", "true")
    .set("mode", _)
    .set("numItineraries", 4);
  // h = opciones del perfil, mezcladas encima
}
```

Y hace **cuatro peticiones en paralelo**, una por pestaña de la UI:

```js
{ bus:     routeRequest(d, h.bus,     "TRANSIT"),
  walk:    routeRequest(d, h.walk,    "WALK"),
  bicycle: routeRequest(d, h.bicycle, "BICYCLE"),
  all:     routeRequest(d, h.all,     "TRANSIT, WALK") }
```

**Perfiles de itinerario** (esto es lo interesante — son pesos de coste generalizado):

| Perfil UI | Parámetros OTP |
|---|---|
| `fast` — "Más rápido" | `optimize=QUICK`, `walkReluctance=10` |
| `fewerTransfers` — "Menos transbordos" | `walkBoardCost=1500`, `transferPenalty=600` |
| `lessWalk` — "Menos caminata" | `walkReluctance=35`, `bikeReluctance=15` |
| Silla de ruedas | `wheelchair=true`, y **fuerza `walkReluctance=1`** |

Velocidades de caminata: **normal 1.4 m/s, lenta 1.2 m/s**.

Y un detalle de diseño que merece la pena copiar:

```js
maxWalkDistance: Math.round(this.speedAndTimeToMetersDistance(this.maxWalkTime(), this.walkSpeed().speed))
```

**El radio de caminata no es un número de metros: es un número de minutos**, convertido a
metros con la velocidad que el usuario haya elegido. Quien anda despacio obtiene un radio más
pequeño automáticamente. Nosotros tenemos `accessRadiusMetres = 800` fijo para todo el mundo.

### 2.6 Cuánta inteligencia hay en el cliente: ninguna

`orderItinerariesResult` es, entero, esto:

```js
h.walk.plan.itineraries.sort((a, b) => a.duration - b.duration)
```

Un `sort` por duración en cada pestaña, y `minDuration` para pintar barras. **Toda la decisión
está en el servidor.** No hay dominancia, no hay Pareto, no hay criterios. El usuario elige
pestaña (bus / a pie / bici / mixto) y perfil, y OTP devuelve 4 itinerarios ya ordenados por
su coste generalizado.

### 2.7 Geocodificación: Pelias

```js
basePath = otpUrl;               // https://planificador-rutas-api.vigo.org/v1/
GET v1/autocomplete?text=…&layers=venue,address&lang=es
GET v1/reverse?point.lat=…&point.lon=…&lang=es
```

`v1/autocomplete`, `v1/reverse`, `layers`, `point.lat` → es **Pelias**, el geocodificador que
acompaña a OTP por defecto. Nosotros usamos MapKit, que para direcciones de Vigo es
comparable o mejor. Aquí no perdemos.

### 2.8 La ventana de 94 días, verificada

Consultas reales al `/plan` del Concello, mismo par origen-destino, misma hora:

| Fecha | Resultado |
|---|---|
| 08-09-2026 (mar) | 3 itinerarios |
| **08-10-2026 (jue, +30 d)** | **3 itinerarios** |
| **15-11-2026 (dom, +69 d)** | **1 itinerario** |

Y comparando por día de la semana:

| Consulta | Itinerarios devueltos |
|---|---|
| Sáb 12-09-2026 | `10:00→10:35 [18A+C3d]`, `10:15→10:39 [15B]` |
| Sáb 14-11-2026 (+63 d) | `10:00→10:35 [18A+C3d]`, `10:15→10:39 [15B]` — **idéntico** |
| Dom 13-09-2026 | `10:00→10:23 [15C]`, `10:06→10:32 [C3i]` |
| Dom 15-11-2026 (+63 d) | idéntico al domingo cercano |
| **Lun 12-10-2026 (Fiesta Nacional)** | **idéntico al DOMINGO**, no al lunes |

Las dos últimas filas son la clave. Un lunes festivo devuelve el horario de domingo. Eso **no
sale de una proyección semanal ingenua**: su grafo tiene un calendario real con festivos, de
94 días. Nosotros tenemos 7.

**Lo que no pude verificar:** de dónde sacan ese calendario. El ZIP público no lo tiene (§3.1).
O Vitrasa les da un feed más largo, o lo componen ellos. Merece una pregunta al Concello antes
de construir nada.

---

## 3. FASE 2 — Nuestro motor

La arquitectura es buena y no la toco: RAPTOR por rondas sobre una `Timetable` precompilada,
función pura de `(Timetable, RaptorQuery)`, verificada contra `BruteForceReference`. Los 19
hallazgos de `AUDITORIA-RAPTOR.md` (H-01 … H-19) están corregidos en las cuatro tandas ya
commiteadas.

Y aun así falla. Estos son los motivos, y ninguno es un bug de RAPTOR.

### F-1 · CRÍTICO — La ventana de 7 días

Descarga del GTFS de hoy (`Last-Modified: Fri, 04 Sep 2026 06:00:56 GMT`), analizada:

```
calendar.txt        → 0 filas (sólo cabecera)
calendar_dates.txt  → 702 filas, exception_type=1 todas
                      7 fechas distintas: 20260905 … 20260911
```

| Fecha | Servicios | Viajes |
|---|---:|---:|
| 05/09 sáb | 64 | 1.104 |
| 06/09 dom | 51 | 788 |
| 07/09 lun | 114 | 1.803 |
| … | | |
| 11/09 vie | 121 | 1.838 |

Siete días. Y `GTFSImporter.import` los destruye en cada refresco:

```swift
for table in ["stopRoute", "stopTime", "shapePoint", "trip",
              "calendarDate", "calendarEntry", "route", "stop"] {
    try db.execute(sql: "DELETE FROM \(table)")
}
```

Es idempotente y limpio — y por eso **nunca acumulamos historia**. `JourneyPlanner` entonces:

```swift
guard let window = feedStatus.window, window.contains(day) else {
    return finish(.outsideFeedWindow(reported), feedStatus: feedStatus)
}
```

**Consecuencia observable:** cualquier consulta a más de 6 días vista devuelve
`.outsideFeedWindow`. "¿Cómo voy al aeropuerto el día 20?" no tiene respuesta. El del Concello
la tiene a 94 días.

Esta es, con diferencia, la clase de fallo más amplia: no da una ruta mala, no da **ninguna**.

### F-2 · CRÍTICO — La caminata es en línea recta

`WalkModel` es haversine × `walkDetourFactor` (1.35), y el propio comentario lo asume:

```swift
/// Everything here is straight-line distance scaled by a detour factor. That is a
/// deliberate limit, not an oversight
```

**Lo medí.** 14 pares de paradas reales separadas 150–800 m en línea recta, consultando el
grafo OSM del propio OTP del Concello (`mode=WALK`) y comparando con nuestro modelo:

| Recta (m) | Calle real (m) | Ratio | Nuestro ×1.35 | Error |
|---:|---:|---:|---:|---:|
| 459 | **855** | **1,86** | 620 | **−27,6 %** |
| 450 | 772 | 1,72 | 608 | −21,3 % |
| 439 | 731 | 1,66 | 593 | −18,9 % |
| 733 | 1.105 | 1,51 | 989 | −10,5 % |
| 408 | 549 | 1,35 | 550 | +0,2 % |
| 320 | 375 | 1,17 | 432 | +15,0 % |
| 593 | 623 | 1,05 | 801 | **+28,6 %** |
| 447 | 468 | 1,05 | 604 | +29,1 % |

```
n=14   ratio real/recta:  min 1,05   p50 1,23   p90 1,66   máx 1,86   media 1,33
```

**La media está bien calibrada. La varianza no lo está.** 1,35 es un promedio excelente para
un valor que en la práctica oscila entre 1,05 y 1,86.

Traducido a lo que ve el usuario, con el peor caso de la tabla:

> **Subida ás Chans → Estrada de Bembrive 3.** Recta 459 m. Calle real **855 m**.
> Nuestro modelo: 620 m ÷ 1,33 m/s = **6 min 18 s**.
> Realidad: 855 m ÷ 1,33 = **10 min 43 s**.
> **Nos faltan 4 minutos y medio.** Le decimos al usuario que llega al autobús. No llega.

Y el error simétrico, igual de real aunque menos visible: cuando sobreestimamos un 29 %,
descartamos enlaces que sí se cogen, y la mejor opción **nunca se genera**.

Esto es exactamente el síntoma de "por más que lo hemos refinado, me sigue fallando": no es un
fallo del planificador, es que la entrada geométrica que le damos tiene ±30 % de ruido.

Agravante local: Vigo tiene desnivel. `WalkModel` no lo modela en absoluto, y el ratio 1,86 de
la primera fila es precisamente una subida.

### F-3 · ALTO — La planificación no usa el tiempo real

Tenemos `ConcelloRealtimeClient`, `ArrivalsService`, `ThrottledRealtimeProvider` y
`ArrivalsCache`. `JourneyPlanner` no toca nada de eso: planifica sobre horario estático puro y
muestra horas teóricas. Cuando un bus va con 6 minutos de retraso, el itinerario que
enseñamos es falso — y peor, el transbordo que calculamos con 90 s de holgura ya no existe.

Nota: el del Concello probablemente tampoco lo hace (no vi `GTFS-RT` en su grafo). **Aquí
podemos ser mejores que ellos**, no sólo igualarlos.

### F-4 · MEDIO — El frente de Pareto de cinco ejes casi no domina nada

`JourneyShortlist.undominated` exige, para que A domine a B, que A gane o empate en **cinco**
ejes (salida, primer embarque, llegada, transbordos, caminata final). Con cinco ejes casi
ningún par se domina, así que el frente sale enorme, y entonces `cut` reparte plazas **por
turnos rotatorios** entre los tres criterios.

El resultado es una lista heterogénea por construcción: cuatro opciones elegidas cada una por
un criterio distinto. El razonamiento del código es correcto y está bien argumentado — evita
sesgar el conjunto por llegada. Pero el efecto práctico es que la lista no se lee como "estas
son tus opciones ordenadas", que es lo que sí consigue OTP con **un coste escalar por perfil**.

### F-5 · MEDIO — El rebarrido de salidas desperdicia pases

`JourneyPlanner.scan` reinicia cada pase en `primer embarque + 1`, y `firstBoardingSeconds`
toma el **mínimo de todo el lote**:

```swift
if earliest == nil || seconds < earliest! { earliest = seconds }
```

Si un itinerario del lote embarca muy pronto en una parada de acceso lejana, el siguiente pase
arranca un segundo después de **ése**, y vuelve a encontrar casi lo mismo desde las paradas
cercanas. Con `maxDepartureScans = 4`, gastar un pase así es caro.

### F-6 · MEDIO — Footpaths: un salto, y ninguno en la ronda 0

Documentado como H-10 y aceptado como latente. Con el dato de F-2 deja de ser tan latente: el
radio de transbordo son **300 m en línea recta**, que con el p90 medido (1,66) son ~500 m
reales. Nuestro colchón de transbordo es `minTransferSeconds 60 + footpathBufferSeconds 30`.
En un transbordo de 300 m recta, el error de geometría se come el colchón entero.

### F-7 · BAJO — No hay `transfers.txt`

Confirmado en el feed. Ni ellos ni nosotros tenemos transbordos oficiales; ambos los
inventamos por proximidad. No es una desventaja relativa, pero explica por qué ninguno de los
dos acierta siempre en estaciones con varias dársenas.

---

## 4. FASE 3 — Comparación directa

| | **Concello (OTP 1.x)** | **ILoveVigoRoutes (RAPTOR)** |
|---|---|---|
| Dónde se calcula | Servidor | Dispositivo |
| Algoritmo | A\* multimodal, coste generalizado | RAPTOR por rondas, Pareto multi-eje |
| Grafo peatonal | **OSM real (callejero)** | **Ninguno** — haversine × 1,35 |
| Calendario | **94 días, con festivos** | **7 días** |
| Fuente de tránsito | GTFS Vitrasa | GTFS Vitrasa — **la misma** |
| Ferry | No | No |
| Tiempo real | No | Disponible, **sin usar en el planificador** |
| Radio de caminata | Minutos → metros, según velocidad del usuario | 800 m fijos |
| Silla de ruedas | `wheelchair=true`, `walkReluctance=1` | **No implementado en el motor** |
| Alternativas | 4 por coste escalar, por perfil | Frente Pareto + corte rotatorio |
| Funciona sin red | No | **Sí** |
| Accesibilidad de la UI | Pobre (según tu criterio) | Buena |

### Qué hacen ellos que nosotros no

1. **Enrutan al peatón por calles.** Es la diferencia de fondo. Todo lo demás es secundario.
2. **Tienen calendario largo con festivos.**
3. **Convierten preferencias en pesos de coste**, no en criterios de ordenación *a posteriori*.
4. **Escalan el radio de caminata con la velocidad del usuario.**
5. **Tienen modo silla de ruedas en el motor.**

### Qué tenemos nosotros que ellos no

Funcionamiento sin red, latencia cero, sin dependencia de infraestructura ajena, accesibilidad
real en la UI, tiempo real disponible, y un motor verificado contra fuerza bruta. **No conviene
tirar nada de esto para copiarlos.**

### Por qué sigue fallando el nuestro pese a los ajustes

Porque las cuatro tandas de la auditoría anterior corrigieron el **algoritmo**, y el problema
está en los **datos que entran**: una geometría peatonal con ±30 % de error y un calendario de
siete días. RAPTOR resuelve impecablemente el problema equivocado.

---

## 5. FASE 4 — Plan de cambios propuesto

Priorizado por cuántos fallos reales corrige primero. **Nada de esto es portar OTP**, y nada
toca la arquitectura SwiftUI + VigoCore + GRDB.

### Tanda A — Ampliar la ventana de calendario *(corrige F-1)*

Lo primero porque es la única clase de fallo en la que hoy **no damos ninguna respuesta**.

- **A0 · Antes de escribir código: preguntar.** Su OTP tiene 94 días con festivos correctos, y
  el ZIP público no. Ese dato existe. Una consulta a `datos.vigo.org` / Vitrasa puede ahorrar
  toda esta tanda. **Hazlo primero.**
- **A1 · Versionar el feed en lugar de borrarlo.** Tabla `feedVersion(id, importedAt,
  windowStart, windowEnd)`, y columna de versión en `calendarDate` / `trip` / `stopTime`.
  `GTFSImporter` deja de hacer `DELETE FROM` a ciegas: inserta una versión nueva y purga las
  que caduquen por fecha (no por número). Con ~8 semanas retenidas cubrimos hacia atrás; hacia
  adelante seguimos con 7 días, así que A1 **sólo** habilita A2.
- **A2 · Proyección semanal etiquetada.** Para un día D fuera de cobertura real, usar el mismo
  día de la semana de la última versión disponible, y marcar el `Journey` como **estimado**.
  La UI ya tiene el vocabulario para esto (`DataProvenanceViews`): banda "horario estimado, no
  confirmado". El README prohíbe la respuesta silenciosamente falsa, y esto la respeta.
- **A3 · Calendario de festivos de Vigo.** JSON en el bundle, ~14 fechas al año. Un festivo se
  proyecta con el patrón de **domingo**, no con el de su día de la semana. Sin A3, A2 miente en
  Navidad, Reconquista y San Roque — que es exactamente cuando más se consulta.
- **Riesgo a medir antes:** tamaño en disco. `stop_times` son ~8 MB por versión. Con 8
  versiones son 64 MB, inaceptable. Mitigación obligatoria: deduplicar — la inmensa mayoría de
  los viajes se repiten idénticos semana a semana, así que versionar sólo `calendarDate` y las
  referencias, no los `stopTime`. **Medir esto antes de comprometerse a A1.**

### Tanda B — Geometría de caminata real *(corrige F-2, F-6)*

- **B1 · Hoy mismo, media hora: separar los factores de detour.** `walkDetourFactor` único →
  dos números: `accessDetourFactor ≈ 1.50` y `transferDetourFactor = 1.35`.
  Razón: subestimar el acceso hace perder el autobús (fallo visible y doloroso); sobreestimarlo
  sólo descarta alguna opción. La asimetría de coste justifica un factor asimétrico.
  **Es un parche, no la solución**, y hay que anotarlo como tal.
- **B2 · Tabla de footpaths reales, precalculada y empaquetada.** 1.149 paradas; los pares a
  menos de 400 m son unos pocos miles. Calcular **una vez, offline en tu máquina**, la
  distancia peatonal real de cada par (con OSRM, Valhalla o un OTP local sobre el OSM de
  Galicia), y enviar el resultado en el bundle como `footpaths.bin` (~100 KB).
  `TimetableBuilder` lo carga en vez de llamar a `WalkModel.footpaths(stops:)`.
  **Elimina F-2 en los transbordos por completo**, sin red, sin dependencia en ejecución, sin
  coste de batería. Es la mejor relación impacto/riesgo de todo el plan.
- **B3 · Acceso y egreso con `MKDirections`.** Origen y destino son puntos arbitrarios, no se
  pueden precalcular. Pedir la caminata real **sólo para las 3–5 paradas candidatas finales**
  (nunca para las 100 de `maxNearbyStops`), cachear por `(coordenada redondeada a 4 decimales,
  stopID)`, y degradar al factor de B1 si no hay red o la petición falla. La UI ya sabe decir
  "estimado".
- **B4 · Radio en minutos, no en metros.** Copiar el diseño del Concello:
  `accessRadiusMetres` deja de ser una constante y pasa a derivarse de un `maxWalkMinutes` y la
  velocidad configurada. Cambio pequeño, y es lo que hace que el modo "camino despacio" sea
  coherente de verdad.
- **B5 · Pendiente (evaluar después de B2/B3).** Regla de Tobler sobre una malla de elevación
  ligera. Vigo lo justifica, pero no antes de haber arreglado la planta.

### Tanda C — Cómo se eligen y ordenan las alternativas *(corrige F-4, F-5)*

- **C1 · Coste generalizado como criterio de corte, no como sustituto.**
  `coste = t_vehículo + wR · t_pie + tP · transbordos + wtR · t_espera`.
  `JourneyOrdering` se queda tal cual — es nuestra ventaja de UX y accesibilidad, y no se toca.
  Lo que cambia es `JourneyShortlist.cut`: en lugar de la rueda rotatoria, cortar por el coste
  generalizado **del criterio activo**. Pesos inspirados en los perfiles reales de OTP:

  | Criterio nuestro | `walkReluctance` | `transferPenalty` |
  |---|---:|---:|
  | Llega antes | 1,0 | 0 s |
  | Menos caminata | 3,5 | 300 s |
  | Sale antes | 1,0 | 0 s (se mantiene el orden actual) |

  Se conservan los tres criterios y desaparece la lista heterogénea.
- **C2 · Arreglar el rebarrido.** `firstBoardingSeconds` deja de tomar el mínimo global del
  lote: reiniciar por **parada de acceso**, o por el embarque del itinerario representante del
  pase. Recupera pases hoy desperdiciados sin subir `maxDepartureScans`.
- **C3 · Modo silla de ruedas en el motor.** `wheelchair_boarding` ya está en `stops.txt` y ya
  lo importamos. Filtrar paradas no accesibles y bajar la reluctancia de caminata, igual que
  ellos. **Presumimos de accesibilidad y este es el único punto donde el Concello nos gana en
  ella.** Alto valor por poco código.

### Tanda D — Tiempo real en la planificación *(corrige F-3)*

- **D1 · Post-ajuste de la primera pierna.** Tras reconstruir, consultar `api2.jsp` para la
  parada de embarque y corregir la salida del primer autobús con el dato real. **No
  replanificar.** Es barato, es lo que más se nota, y es honesto: la primera pierna es la que
  el usuario está a punto de vivir.
- **D2 · Sólo si D1 se queda corto:** invalidar y recalcular itinerarios cuyo primer autobús ya
  pasó.

### Cómo verificar que todo esto funciona

**`OTPDifferentialTests`** — el mejor uso que le podemos dar al planificador del Concello.
Igual que ya existe `BruteForceReference` como oráculo de optimalidad, montar un test
diferencial que compare N pares origen-destino contra su `/plan` y falle cuando divergimos más
de X minutos. **Ejecutado en tu máquina, no en la app.** Convierte "me sigue fallando" en un
número que sube o baja con cada cambio.

Nota de método: consultas puntuales y espaciadas, no un barrido masivo. Es infraestructura
pública municipal, y no hay motivo para castigarla.

### Lo que NO hay que hacer

- **No portar OTP.** Es un servidor Java con un grafo de cientos de MB.
- **No cambiar RAPTOR por A\*.** RAPTOR es mejor para lo nuestro: da el frente de Pareto
  (llegada × transbordos) gratis, y está verificado contra fuerza bruta. El problema nunca fue
  el algoritmo.
- **No depender de su OTP en tiempo de ejecución como camino principal.** Perderíamos el
  funcionamiento sin red, que es una ventaja real, y quedaríamos atados a infraestructura
  ajena sin acuerdo. Como oráculo de pruebas, sí. Como motor de producción, no.

### Orden recomendado

```
A0  preguntar por el feed largo         ·  hoy, coste cero, puede ahorrar la tanda A entera
B1  factores de detour asimétricos      ·  hoy      · alivia el fallo más doloroso
B2  footpaths reales precalculados      ·  1 semana · elimina la causa raíz en transbordos
A1+A2+A3  ventana de calendario         ·  1-2 sem. · desbloquea una clase entera de consultas
C1+C2  coste generalizado y rebarrido   ·  días     · la lista deja de ser heterogénea
C3  silla de ruedas                     ·  días     · cierra nuestra única brecha de accesibilidad
D1  tiempo real en la primera pierna    ·  días     · nos pone por delante de ellos
B3  MKDirections en acceso/egreso       ·  después  · el último tramo de precisión
B4  radio en minutos                    ·  con B3
```

Justificación del orden: **B1 es cambiar un número** y reduce hoy mismo los itinerarios
imposibles de coger. **B2 no tiene coste en ejecución** y borra la causa raíz donde más duele.
**A** es la que más trabajo cuesta, pero es la única que convierte "no tengo respuesta" en
"tengo una respuesta etiquetada como estimada" — y eso, en una app de transporte, es la
diferencia entre servir y no servir.

---

## 6. Registro de ejecución

Estado de cada punto del plan. Se actualiza al cerrar cada uno.

| Punto | Estado | Commit |
|---|---|---|
| A0 · Preguntar por el feed largo | **pendiente — acción humana** | — |
| B1 · Factores de detour asimétricos | ✅ hecho | `b1` |
| B2 · Footpaths reales precalculados | ✅ hecho | `b2` |
| A1 · Versionar el feed | ❌ **descartado — innecesario** | — |
| A2 · Proyección semanal etiquetada | ✅ hecho | `a2` |
| A3 · Calendario de festivos | ✅ hecho | `a3` |
| C1 · Coste generalizado en el corte | ✅ hecho | `c1` |
| C2 · Rebarrido de salidas | ❌ **retirado — medido, no hacía falta** | — |
| C3 · Modo silla de ruedas | ✅ hecho | `c3` |
| D1 · Tiempo real en la primera pierna | ✅ hecho (parcialmente ya existía) | `d1` |
| B3 · MKDirections en acceso/egreso | pendiente | |
| B4 · Radio en minutos | pendiente | |
| Tests diferenciales contra OTP | pendiente | |

### A0 — Pendiente, y es tuyo

No lo puedo hacer yo. Su OTP tiene 94 días de calendario **con festivos correctos** y el ZIP
público tiene 7 días. Ese dato existe en algún sitio. Antes de invertir en A1–A3, pregunta:

- A `datos.vigo.org` / el portal de datos abiertos: si publican un GTFS con calendario largo.
- A Vitrasa: si el feed que entregan al Concello para el planificador es distinto del público.

Si la respuesta es que sí, **A1–A3 se caen enteras** y se sustituyen por cambiar una URL.
Merece la pena preguntar antes de construir el andamio.

### B2 — Footpaths reales precalculados ✅

**Qué cambió.** Las distancias a pie **entre paradas** ya no se estiman: se miden una vez,
fuera de la app, sobre el callejero peatonal de OpenStreetMap, y viajan en el bundle.

- `Tools/build_footpaths.py` — construye el grafo peatonal desde un volcado de Overpass
  (`Tools/overpass_walk.ql`), se queda con la componente conexa mayor, engancha cada parada
  a su nodo más cercano y corre un Dijkstra acotado desde cada una.
- `VigoCore/Sources/VigoCore/Resources/footpaths.csv` — la salida. **3.220 pares**, ~55 KB.
- `FootpathTable` — la carga y la consulta. `WalkModel.footpaths(stops:table:)` la cree.

**Lo que salió al generarla:**

```
paradas               1154
nodos / aristas OSM   228.528 / 245.895
componente mayor      206.249 nodos (90,3 % de lo enrutable)
paradas enganchadas   1154   (huérfanas 0)
pares candidatos      11.337
pares escritos        3.220
ratio real/recta      p10 1,07   p50 1,26   p90 2,01   máx 23,33
```

**El máximo de 23,33 es el hallazgo.** No es un error de datos, es el caso que el modelo en
línea recta no puede ver:

| Recta | Calle real | Factor | Paradas |
|---:|---:|---:|---|
| **5 m** | **112 m** | ×23,3 | Avda. de Samil 15 ↔ Samil por Coia |
| 10 m | 166 m | ×16,2 | Avda. das Camelias 3 ↔ Avda. das Camelias 8 |
| 6 m | 101 m | ×15,8 | Rúa de Tomás A. Alonso 86 ↔ 13 |
| 14 m | 177 m | ×12,8 | Rúa do Seixo 45 ↔ 38 |

Son postes gemelos a un lado y otro de una avenida sin paso de peatones entre ellos. El modelo
antiguo le daba a ese transbordo **5 segundos**. Son 85. Cada uno de estos pares era un enlace
que la app ofrecía y que nadie podía hacer — y son precisamente los que más aparecen, porque
son los más cercanos.

**Validación contra un grafo independiente.** Doce pares al azar de la tabla, contra el OTP del
Concello (que enruta sobre su propio OSM):

```
error absoluto medio 10,9 %   mediana 3,6 %   máximo 47,6 %
```

Mediana del **3,6 %**, frente al ±30 % del modelo en recta. Los dos casos peores (+47 %, +32 %)
son cruces que su grafo permite y el nuestro no; nuestro número es el conservador de los dos,
que en un transbordo es el lado seguro.

**Reglas de la tabla, y por qué.** `FootpathTable` distingue tres situaciones, porque la
ausencia de un par significa dos cosas distintas:

| Situación | Qué se hace |
|---|---|
| El par está medido | Se usa la distancia real |
| Ambas paradas medidas, el par no aparece | **No hay transbordo.** El generador miró y no encontró ruta dentro del radio |
| Alguna parada no está en la tabla | Se estima en recta, como antes |

La tercera regla es la que evita que una parada nueva del feed se quede sin ningún transbordo
hasta que alguien regenere el recurso.

**Cambio de unidad.** `maxTransferWalkMetres` pasa de 300 m *en recta* a **400 m caminados**.
No es un ensanche: 300 × 1,35 ya eran ~405 m de acera. Ahora el número significa lo que el
pasajero recorre.

**Un bug encontrado por su propio test.** `FootpathTable.load` partía el CSV con
`split(separator: "\n")`. Swift trata `\r\n` como **un solo `Character`**, así que un fichero
con finales de línea de Windows no se partía en absoluto: volvía como una sola línea, se
descartaba por empezar con la cabecera, y `load` devolvía una tabla vacía **sin lanzar ningún
error**. El planificador habría vuelto a estimar en línea recta en silencio — justo la clase de
fallo mudo que el README prohíbe. Corregido, y con test.

Por el mismo motivo hay un test que comprueba que el recurso empaquetado **existe y tiene
forma**: `bundled` se traga cualquier fallo y degrada a `.empty` a propósito (un error de
empaquetado no debe tirar la app), y esa decisión necesita una alarma que la vigile.

**Atribución.** Los datos son © colaboradores de OpenStreetMap, ODbL. Añadida a
`DataSourcesView` junto a las demás fuentes.

**Lo que esto NO arregla.** El acceso y el egreso —del portal a la primera parada y de la
última al destino— siguen en línea recta, porque esos extremos son donde esté el usuario y no
se pueden precalcular. Eso es B3.

**Verificación.** 400 tests en 46 suites, verde. Nueve nuevos.

### A1 — Descartado, y por qué

El plan original proponía versionar el feed —conservar ocho semanas de `trip` y `stopTime`—
para poder responder más allá de la ventana de siete días, y yo mismo marqué sus 64 MB como
riesgo a medir antes de comprometerse. Al medirlo resultó que **el problema no era ése**.

Para contestar "¿cómo voy el martes que viene?" no hacen falta los horarios de semanas
pasadas. Hace falta saber **qué `service_id` circulan ese martes** — y los viajes de esos
servicios ya están en la base de datos, porque el feed de esta semana los trae. Lo único que
falta es la fila del calendario que dice "el 20 de octubre corren estos servicios".

Así que se proyecta **el conjunto de servicios, no los horarios**. Cero coste en disco, cero
migración de esquema, y el mismo resultado. A1 se cae entera y su trabajo lo hace A2.

### A3 — Calendario de festivos ✅

Va antes que A2 porque A2 sin esto miente, y miente el día que más gente consulta.

**El problema que resuelve.** La proyección reutiliza el mismo día de la semana más reciente.
Para un martes normal es correcto. Para un martes que es 25 de diciembre es falso: circula
horario de domingo. Y el error va en las dos direcciones — un festivo **dentro** de la ventana
observada tampoco puede servir de plantilla, o una semana capturada que incluya el 12 de
octubre propagaría horario de festivo a todos los lunes durante dos meses.

**Qué hay.** `HolidayCalendar` + `Resources/holidays-vigo.json`, en tres tramos con fiabilidad
distinta y declarada:

| Tramo | Fuente | Fiabilidad |
|---|---|---|
| Fijos nacionales y de Galicia | Ley, estables | Alta |
| Derivados de la Pascua (Xoves e Venres Santo) | **Calculados**, algoritmo de Meeus | Exacta |
| Locales de Vigo | Los fija el Concello cada año, DOG | **Caducan — revisión anual** |

La Pascua se calcula en vez de tabularse: una tabla sería una cosa más que actualizar cada año,
y la fórmula es exacta para cualquier año gregoriano. Hay un test que lo comprueba en
**1900–2200**: siempre en domingo, siempre entre el 22 de marzo y el 25 de abril.

**Sobre los festivos locales, sin adornos.** No los puedo verificar. Los fija el Concello
anualmente y se publican en el DOG. En el JSON van marcados `VERIFICAR en el DOG` y el bloque
`_comment` dice que hay que repasarlos cada año y que ampliar `lastYear` sin añadir los
`local` de esos años deja años con festivos nacionales y sin los de la ciudad. **Esto es una
tarea recurrente tuya, no un dato resuelto.**

**Por qué una lista imperfecta es aceptable igualmente.** Contención: un festivo mal puesto
sólo puede afectar a un día que **ya se está proyectando**, y todo día proyectado se etiqueta
como estimado en la interfaz (A2). Degrada una respuesta que nunca se presentó como firme, y
no puede tocar jamás un día que el feed sí cubre, porque un dato observado no se proyecta.

`covers(year:)` distingue "no es festivo" de "no sé nada de ese año". A2 se niega a proyectar
más allá de los años expandidos en vez de adivinar.

**Verificación.** 408 tests en 47 suites, verde. Ocho nuevos, incluido el caso observado: el
12 de octubre de 2026 es lunes y el planificador del Concello devuelve para ese día horario de
domingo (§2.8). Es la observación que motivó el fichero y la primera que se rompería si
alguien lo vaciara.

### A2 — Proyección semanal etiquetada ✅

**El acantilado de los siete días ha desaparecido.** Antes, cualquier consulta a más de seis
días vista devolvía `.outsideFeedWindow`: no una respuesta mala, **ninguna**. Ahora un día que
el feed no alcanza toma prestados los servicios del día equivalente más reciente, y la
respuesta dice que es una estimación.

**Qué se proyecta.** Sólo el **conjunto de `service_id`** que circulan ese día. Los viajes de
esos servicios y sus horarios ya están en la base: los trajo el feed de esta semana. Cero
duplicación, cero migración de esquema, cero coste en disco.

**Las reglas, y por qué cada una** (`ServiceDayResolver`):

| Regla | Motivo |
|---|---|
| Un día observado nunca se proyecta | El dato real siempre gana. Es lo que garantiza que un error en el calendario de festivos no pueda corromper una respuesta firme |
| El pasado se rechaza | Nadie planifica un viaje para el martes pasado, y proyectar hacia atrás sería responder a una pregunta sobre el pasado con una conjetura sobre él |
| Más de 60 días, se rechaza | Un horario proyectado a tres meses es ficción disfrazada de dato |
| Un año sin calendario de festivos, se rechaza | Sin él no hay forma de distinguir un martes normal de Navidad. Proyectar a ciegas es la respuesta falsa silenciosa que este proyecto prohíbe |
| Un festivo se proyecta desde un domingo | Es el horario que circula |
| Un festivo nunca es plantilla | La dirección fácil de olvidar: una semana capturada con el 12 de octubre dentro propagaría horario de festivo a todos los lunes durante dos meses |

Sesenta días y no los noventa y cuatro del Concello: pasados dos meses la pregunta que se
responde es más rara que la confianza que se colocaría mal.

**Sólo días con servicio real sirven de plantilla.** `observedServiceDays()` devuelve los días
que el feed describe **y** en los que circula algo. Un día cubierto pero con todos los
servicios cancelados no es plantilla de nada: proyectarlo le daría a todos los martes futuros
un horario sin autobuses.

**El reloj no se toma prestado, sólo los servicios.** El constructor usa la medianoche del día
*consultado*, no la de la plantilla. Proyectar el último domingo de octubre —el del cambio de
hora— sobre un domingo de noviembre arrastraría si no un día de 25 horas.

**Etiquetado, y de forma accionable.** `PlanResult.schedule` lleva `.observed` o
`.projected(template:)`. `PlanOutcomeMessage.estimateNotice` devuelve `nil` para lo observado
—un aviso que sale siempre deja de leerse— y para lo proyectado **nombra el día del que salen
los horarios**. «Estimado» a secas no es accionable: dice que desconfíes sin decirte cuánto. Un
martes tomado del martes pasado se puede usar; el mismo martes tomado de hace dos meses hay que
confirmarlo.

En el mapa aparece sobre las alternativas, en naranja y con icono de aviso.

**Un invariante que costó una decisión de diseño.** Seis transiciones distintas devuelven la
ruta a `.idle`. Pedirle a cada una que se acuerde de limpiar también el horario es la clase de
contabilidad que se pudre: un sitio olvidado y un aviso de «estimado» queda flotando sobre
resultados firmes. Por eso `estimateNotice` está atado a `route` y no sólo a `schedule` — el
estado obsoleto no es improbable, es **irrepresentable**.

**`outsideFeedWindow` cambia de significado**, y su mensaje con él. Ya no es «el feed dura una
semana» sino «ni siquiera se puede estimar»: una fecha pasada, o tan lejana que reutilizar una
semana vieja sería inventar. El texto dice ahora *datos confirmados*.

**Verificación.** 427 tests en 49 suites, verde. Diecisiete nuevos entre `ServiceDayResolver`,
el planificador y el aviso del mapa — incluido uno que comprueba que un festivo mal puesto no
puede alterar un día observado, y otro que fija que la misma pregunta da siempre la misma
respuesta (`observedDays` es un `Set`, y depender de su orden de iteración daría horarios
distintos en dos arranques de la misma app con los mismos datos). La app compila.

### C2 — Retirado. Lo medí y no era verdad

Escribí en la Fase 2 que el rebarrido desperdiciaba pases porque reinicia un segundo después
del embarque **más temprano de todo el lote**. Lo diagnostiqué leyendo el código. Al medirlo
contra el feed real, sobre cuatro pares origen-destino:

```
16 pases en total, 1 sin aportar ningún trayecto nuevo
```

Y ese único pase estéril fue seguido de otros dos que aportaron tres trayectos, así que el
corte temprano que iba a añadir habría **empeorado** la respuesta. La regla de reinicio actual
hace justo lo que debe: cada pase encuentra "el siguiente autobús" para la parada que tenía el
más temprano.

Retirado. Queda como test de regresión en `ShortlistRealFeedTests`, para que si alguien cambia
la regla de reinicio se entere.

### C1 — Coste generalizado para podar alternativas ✅

**La premisa sí se confirmó, y era peor de lo que dije.** Medido contra el feed real:

| Consulta | Únicos | Frente de Pareto | Abarcaba |
|---|---:|---:|---:|
| Príncipe → Cunqueiro | 5 | **5** (no descartó nada) | 48 min |
| Samil → Urzáiz | 10 | **10** (no descartó nada) | 42 min |
| Camelias → Samil | 7 | 6 | 84 min |
| Suárez Llanos → Bembrive | 9 | 6 | 60 min |

La dominancia de cinco ejes **no descarta nada** en la mitad de las consultas. Y entre lo que
deja pasa esto (Suárez Llanos → Bembrive, medido):

```
sale 9:31  llega 10:08  camina 0 s  1 transbordo   C3i+6
sale 9:46  llega 10:30  camina 0 s  2 transbordos  5B+H2+6
```

El segundo llega más tarde, cambia una vez más y no camina menos. Sobrevive **sólo porque sale
después** — el eje de H-05, «menos rato de pie en la parada», que no tiene tope: por muy tarde
que sea, sigue puntuando. En los términos del frente es legítimamente no dominado. Y no es
alternativa de nadie.

**Dos borradores, y el primero estaba mal.** Vale la pena contarlo porque el error es
instructivo.

*Primer intento:* coste medido desde el reloj de la consulta, como hace OTP. Funcionó
demasiado bien:

```
Príncipe → Cunqueiro:  ANTES n=5 abarca 48 min  →  AHORA n=1 abarca 0 min
```

Las cuatro que tiraba eran los autobuses de las 9:37, 9:39, 9:50 y 10:01. **No eran basura:
eran los siguientes autobuses**, que es la mayor parte de para qué sirve una lista de
alternativas. Cobrar por llegar tarde borra la lista; cobrar por ser ineficiente no.

*Segundo intento:* el coste mide el trayecto **desde su propia salida**. Dos salidas idénticas
separadas media hora cuestan exactamente lo mismo.

*Y aun así faltaba algo.* Con eso, el caso de Bembrive descartaba el 9:22 — que es el óptimo de
«sale antes». La poda corre **antes** de que el usuario elija criterio, así que tirar el óptimo
de cualquiera de ellos es exactamente el pecado de H-04 y H-05, reintroducido un paso antes.
Ahora **el ganador de cada criterio se conserva incondicionalmente**, antes de mirar ningún
coste.

**Resultado final, medido:**

```
Príncipe → Cunqueiro:      5 → 4   (cae el de 322 s de caminata final)
Samil → Urzáiz:            8 → 7
Camelias → Samil:          6 → 4
Suárez Llanos → Bembrive:  6 → 3   (caen el 9:46 de dos transbordos y los dos de las 9:55)
```

Siete de veinticinco podadas, ningún óptimo perdido, las salidas sucesivas intactas.

**Los pesos**, análogo local de los perfiles que el Concello manda a OTP (§2.5,
`walkReluctance` 10 frente a 35, `transferPenalty` 600):

| Criterio | Coste |
|---|---|
| Llega antes / Sale antes | viaje + caminata total + 300 s × transbordos |
| Menos caminata | lo mismo **+ 2 × caminata final** |

«Sale antes» comparte coste con «llega antes» a propósito: la poda pregunta *si el trayecto es
decente*, y salir antes no cambia lo que hace decente a un trayecto — cambia cuál se enseña
primero, y de eso ya se encarga `isBefore`. Darle un coste propio que premiara salir pronto
readmitiría justo el 9:46 de dos transbordos.

**Verificación.** 441 tests en 51 suites, verde. Trece nuevos, más cuatro contra el feed real
en `ShortlistRealFeedTests` (con `VIGO_GTFS_ZIP`), que fijan las cuatro propiedades medidas:
los pases del rebarrido son productivos, la dominancia sola apenas filtra, la poda recorta sin
quitarle a ningún criterio su respuesta, y conserva más de una salida. Esos cuatro tests son lo
que atrapó los dos borradores fallidos; un fixture sintético no te dice que un filtro se está
comiendo los cuatro autobuses siguientes.

### C3 — Modo silla de ruedas ✅

**Primero, lo que descubrí y cambió el plan.** El plan decía «`wheelchair_boarding` ya está en
`stops.txt` y ya lo importamos: filtrar paradas no accesibles». Lo comprobé:

```
stops.txt   wheelchair_boarding=1  →  1154 de 1154
trips.txt   wheelchair_accessible=1 →  3801 de 3801
```

**El feed declara accesible el 100 % de todo.** Filtrar por esos campos sería un no-op que
*parecería* un modo silla de ruedas. Eso es lo peor que se puede hacer aquí: quien depende de
esa información es quien menos margen tiene para absorber una respuesta equivocada. Así que no
se filtra por ahí, y el código lo dice.

**Lo que sí se puede afirmar con datos: la acera.** Mi extracto de OSM para B2 incluía
`highway=steps`. Una escalera es un enlace peatonal perfectamente válido y un muro para alguien
en silla, y esa diferencia hay que hacerla **en el grafo**, no en las distancias — porque la
alternativa es otra ruta, no una versión más larga de la misma.

`Tools/build_footpaths.py --exclude-ways` genera una segunda tabla sobre un grafo del que se
han quitado 790 vías: escaleras, vías con `wheelchair=no` y pendientes fuertes
(`Tools/overpass_barriers.ql` dice exactamente qué). Resultado:

| | A pie | En silla |
|---|---:|---:|
| Transbordos medidos | 3.220 | 3.159 |
| **Desaparecen** (no hay ruta sin escaleras) | — | **62** |
| Se alargan | — | 54 |

Los rodeos más grandes:

| A pie | En silla | Paradas |
|---:|---:|---|
| **84 m** | **336 m** | Avda. de Vigo 161 ↔ 230 |
| 153 m | 387 m | Estrada de Bembrive 278 ↔ Rúa da Cruz 2 |
| 118 m | 351 m | Estrada de Bembrive 278 ↔ 269 |

Un transbordo de 84 metros que en realidad son 336. Eso no es un ajuste fino.

**Cómo viaja el perfil.** En `PlanQuery`, no en la configuración de la app: alguien puede
planificar un viaje para sí y el siguiente para un familiar, y un ajuste global convertiría eso
en un viaje a la pantalla de ajustes y vuelta. También es lo que permite que un solo
`JourneyPlanner` y un solo `TimetableStore` sirvan a los dos perfiles — con el perfil dentro de
la clave de caché, porque un horario construido para uno es falso para el otro.

**Velocidad.** 1,0 m/s en silla frente a 1,33 a pie. Es política, no una medición: yerra por lo
prudente igual que la cifra a pie, y el margen importa más aquí porque el coste de perder el
autobús es mayor. Está separada y con nombre propio para poder revisarla sin tocar la otra.

**En la interfaz**, un interruptor —«Ruta sin escaleras»— y no un menú: son dos estados, y un
menú escondería cuál está activo. Cambiarlo **vacía la respuesta y vuelve a buscar**, no la
reordena: dejar en pantalla trayectos calculados a pie bajo una etiqueta de silla de ruedas
sería la peor mentira que esta app puede contar. `setAccessibility` lo hace imposible de
olvidar.

Y la nota al pie promete sólo lo que los datos sostienen:

> Los tramos a pie rodean escaleras, tramos marcados como no accesibles y cuestas fuertes. No
> podemos confirmar la accesibilidad de cada parada ni de cada autobús: el Concello los declara
> todos accesibles y no publica el detalle.

**Un artefacto conocido.** 13 pares salen hasta 8 m *más cortos* en silla. No es un error de
enrutado: el grafo en silla es un subgrafo, su componente conexa mayor es menor, y unas pocas
paradas enganchan a otro nodo con distinto residuo. Sobre caminatas de cientos de metros es
ruido del método de enganche, está documentado en el generador y el test lo contempla con
tolerancia explícita en vez de fingir que no ocurre.

**Verificación.** 449 tests en 52 suites, verde. Ocho nuevos. La app compila.

### D1 — Tiempo real en la primera pierna ✅

**Corrección a la Fase 2.** Escribí que «tenemos `ConcelloRealtimeClient` y `ArrivalsService`
pero `JourneyPlanner` no toca nada de eso». Lo primero es cierto y lo segundo también, pero la
conclusión era falsa: miré sólo el planificador y me perdí `FirstBoardingMatch` y
`FirstBoardingLive`. **La app ya anotaba el primer embarque con cuenta atrás real**, insignia
de confianza (vehículo localizado frente a estimación del operador) y aviso de «Ya ha salido».
Y con un diseño mejor que el que yo proponía: una petición por parada de embarque distinta, no
por alternativa.

Así que D1 se reduce al hueco que sí quedaba, y que es real: **ese retraso no llegaba a
ninguna parte**. La fila seguía enseñando la hora de llegada del horario mientras la insignia
de al lado decía que el autobús lleva ocho minutos de retraso. Los dos números no pueden ser
ciertos a la vez, y el que el pasajero usa para decidir —¿llego a tiempo?— era el equivocado.

`LiveJourneyAdjustment` cierra eso, con un límite honesto:

| Trayecto | Qué se dice |
|---|---|
| Directo, autobús con retraso | **«llegarías 10:16 (+8 min)»** — el mismo autobús va tarde todo el viaje |
| Con transbordo, margen suficiente | Sólo el retraso. **No se inventa hora de llegada** |
| Con transbordo, el retraso se come el margen | **«Con este retraso pierdes el transbordo»** o «Transbordo justo: N min de margen» |

**Por qué no se traslada el retraso a través de un transbordo.** Pasado el cambio de autobús la
llegada no es «más tarde», es **desconocida**: o el enlace sigue funcionando y el resto va en
hora, o no funciona y el siguiente vehículo puede estar veinte minutos por detrás. Dar una hora
ahí sería inventarla.

**El margen se calcula del propio trayecto, no de `PlannerOptions`.** El plan que está en
pantalla es el que la persona va a seguir, y son sus horas las que deciden si aún se sostiene —
no los mínimos de política que usó la búsqueda al construirlo. Y se le resta la caminata del
transbordo: contar el hueco entero diría que hay cinco minutos de margen cuando cuatro se van
andando entre andenes.

**Umbral: dos minutos.** La fuente informa en minutos enteros y nuestras cifras de caminata son
estimaciones; por debajo de eso todo está dentro del ruido de ambas, y un aviso que salta con
el ruido es un aviso que nadie lee. En el caso normal la fila no cambia.

**Lo que sigue sin hacerse, a propósito.** Nada de esto realimenta al planificador. El tiempo
real **anota y nunca decide** — se decidió en la Fase 3 y sigue igual: la fuente no ve la red,
sólo la parada donde está el pasajero, y una búsqueda medio informada por datos en vivo daría
respuestas sobre las que nadie puede razonar.

**Verificación.** 459 tests en 53 suites, verde. Diez nuevos. La app compila.

### B1 — Factores de detour asimétricos ✅

**Qué cambió.** `PlannerOptions.walkDetourFactor` (un número, 1.35) se parte en dos:

| | Antes | Ahora |
|---|---|---|
| Acceso / egreso / puerta a puerta | 1.35 | **1.50** |
| Transbordo entre paradas | 1.35 | 1.35 |

`WalkModel` gana un tipo `WalkKind { accessEgress, transfer }` y **todas** sus conversiones
lo exigen: `seconds(metres:as:)`, `metres(forSeconds:as:)`, `seconds(from:to:as:)`. Sin valor
por defecto, a propósito — pasar el tipo equivocado es un error silencioso de hasta un 11 % en
una cifra que el usuario usa para decidir si le da tiempo a llegar, así que se paga en el
compilador y no en la parada del autobús.

**Por qué asimétrico.** Los dos errores no cuestan lo mismo:

- Subestimar el acceso → le decimos que llega al autobús y no llega. Fallo ruidoso, el que
  motivó todo esto.
- Sobreestimar el acceso → descartamos una opción que el siguiente barrido de salidas o una
  parada más cercana suelen recuperar. Fallo silencioso y barato.

En transbordos la asimetría se invierte: un transbordo sobreestimado cruza
`maxTransferWalkMetres` y **desaparece del grafo de footpaths**, y nada aguas abajo recupera
un enlace que nunca se construyó. Por eso ahí se mantiene la media medida (1.33 ≈ 1.35).

**Lo que esto NO arregla.** Sigue siendo una distribución con ±30 % de dispersión, sólo que
ahora está centrada donde el error barato. La causa raíz —distancia en línea recta— la
atacan B2 (transbordos) y B3 (acceso/egreso). Está anotado como *stopgap* en el propio código.

**Verificación.** 387 tests en 45 suites, verde. Dos nuevos:
- `accessIsThePessimisticEnd` — un acceso nunca sale más barato que el mismo tramo como
  transbordo, para toda distancia de 25 a 800 m.
- `roundTrip` — `metres → seconds → metres` cierra dentro del error de redondeo para los dos
  tipos, y se comprueba que cruzarlos sí produce la discrepancia que el parámetro evita.

---

## Anexo — Reproducir los sondeos

```bash
# Identidad y ventana del grafo del Concello
curl -s "https://planificador-rutas.vigo.org/otp/routers/default" | python3 -m json.tool

# Feeds y rutas cargadas
curl -s "https://planificador-rutas.vigo.org/otp/routers/default/index/feeds"
curl -s "https://planificador-rutas.vigo.org/otp/routers/default/index/routes"

# Un plan (fechas en MM-DD-YYYY, hora en 'h:mm AM')
curl -s -G "https://planificador-rutas.vigo.org/otp/routers/default/plan" \
  --data-urlencode "fromPlace=42.2358735,-8.7200833" \
  --data-urlencode "toPlace=42.1910340,-8.7143031" \
  --data-urlencode "date=09-08-2026" --data-urlencode "time=9:00 AM" \
  --data-urlencode "mode=TRANSIT,WALK" --data-urlencode "numItineraries=3"

# Caminata real sobre el grafo OSM (para calibrar WalkModel)
curl -s -G "https://planificador-rutas.vigo.org/otp/routers/default/plan" \
  --data-urlencode "fromPlace=LAT,LON" --data-urlencode "toPlace=LAT,LON" \
  --data-urlencode "mode=WALK" --data-urlencode "date=09-08-2026" \
  --data-urlencode "time=9:00 AM" --data-urlencode "numItineraries=1"
```
