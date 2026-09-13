# DATA-SOURCES.md — Verificación de fuentes (Fase 0)

**Fecha de verificación:** 2026-09-04 (04:30–04:50 CEST)
**Verificado por:** Fase 0 del handoff `ILoveVigoRoutes-HANDOFF.md`, puntos 1–6.
**Método:** descarga directa, validación propia en Python, lectura del código de los proyectos
comunitarios de referencia, y pruebas reales con `curl` contra los endpoints en vivo.

> Todo lo que sigue está **observado**, no asumido. Donde no pude verificar algo, lo digo
> explícitamente en la sección [§7 Qué NO pude verificar](#7-qué-no-pude-verificar-y-por-qué).

---

## 1. Resumen ejecutivo

| Fuente | Estado | Confianza |
|---|---|---|
| GTFS estático Vitrasa | **Vivo y fresco** (regenerado 2026-08-31), estructuralmente impecable | Alta — verificado |
| Tiempo real (API Concello `api2.jsp`) | **Vivo**, JSON, ISO-8859-1 | Alta — verificado con `curl` |
| InfoBus HTML (`infobus.vitrasa.es`) | **Vivo**, pero **rediseñado** respecto a lo que parsea VigoBusAPI | Alta — verificado |
| Dataset `paradas` del Concello | **Vivo**, coincide 1:1 con el GTFS | Alta — verificado |
| Horarios de ferry | **No obtenibles de forma estructurada** | Baja — ver §6 |

**Titular:** la premisa del handoff de que el GTFS podría estar caducado desde enero de 2024
es **incorrecta**. El fichero de datos se regenera semanalmente. Lo que está congelado en
enero de 2024 es el *registro de catálogo de CKAN*, no el dato. Ver §2.4.

---

## 2. GTFS estático de Vitrasa

### 2.1 Descarga

```
GET https://datos.vigo.org/data/transporte/gtfs_vigo.zip
```

Cabeceras de respuesta observadas (2026-09-04 02:34:35 GMT):

```
HTTP/1.1 200 OK
Server: nginx
Content-Type: application/zip
Content-Length: 16669245
Last-Modified: Mon, 31 Aug 2026 04:31:47 GMT
ETag: "6a9503b3-fe5a3d"
Accept-Ranges: bytes
Access-Control-Allow-Origin: *
```

- Tamaño: **16.669.245 bytes** (~15,9 MiB).
- **`ETag` y `Last-Modified` presentes** → el refresco condicional (`If-None-Match` /
  `If-Modified-Since`) es viable y es la forma correcta de no molestar a la fuente.
- `Accept-Ranges: bytes` → soporta descarga parcial (no lo necesitamos).

### 2.2 Contenido del ZIP y frescura real de los ficheros internos

Los 8 ficheros internos llevan **todos** fecha `2026-08-31 04:31`, coherente con el
`Last-Modified` del ZIP. No hay ficheros rancios mezclados.

| Fichero | Bytes | Filas (sin cabecera) |
|---|---:|---:|
| `agency.txt` | 186 | 1 |
| `calendar.txt` | 98 | **0** (solo cabecera) |
| `calendar_dates.txt` | 18.992 | 632 |
| `routes.txt` | 3.410 | 59 |
| `trips.txt` | 287.287 | 3.630 |
| `stops.txt` | 118.867 | 1.149 |
| `stop_times.txt` | 8.243.014 | 135.809 |
| `shapes.txt` | 7.996.577 | 139.611 |

**Ausentes:** `feed_info.txt`, `transfers.txt`, `frequencies.txt`, `fare_attributes.txt`,
`fare_rules.txt`.

**`shapes.txt` SÍ está presente** (resuelve el hueco de información #5 del handoff):
139.611 puntos, 226 `shape_id` distintos, y **los 226 están referenciados** por algún viaje.
Cero shapes huérfanos, cero viajes sin shape. Los trazados de línea están cubiertos al 100 %.

### 2.3 Validación de integridad (punto 2 de la Fase 0)

No había validador de MobilityData en el entorno, así que escribí una validación propia sobre
las comprobaciones que exige el handoff. **Resultado: el feed es estructuralmente impecable.**

Integridad referencial — **cero errores**:

| Comprobación | Resultado |
|---|---:|
| `trips.route_id` → `routes` huérfanos | 0 |
| `trips.service_id` → calendario huérfanos | 0 |
| `trips.shape_id` → `shapes` huérfanos | 0 |
| viajes sin `shape_id` | 0 |
| `stop_times.trip_id` → `trips` huérfanos | 0 |
| `stop_times.stop_id` → `stops` huérfanos | 0 |
| viajes con cero `stop_times` | 0 |
| paradas nunca servidas | 0 |
| rutas con cero viajes | **16** (ver §2.6) |

Formatos de hora en `stop_times` — **cero errores**:

| Comprobación | Resultado |
|---|---|
| `HH:MM:SS` malformados | 0 |
| `arrival_time`/`departure_time` vacíos | 0 |
| horas ≥ `24:00:00` | **1.773** (correcto en GTFS, no es un error) |
| hora mínima | `05:00:00` |
| hora máxima | **`30:31:00`** |
| secuencias no monótonas dentro de un viaje | 0 |

> **Consecuencia para el importador:** hay 1.773 tiempos que pasan de medianoche, con máximo
> `30:31:00`. El parser **debe** tratar la hora como *segundos desde el inicio del día de
> servicio*, no como `Date`/`DateComponents`. Un `DateFormatter` con `HH:mm:ss` fallaría en
> silencio sobre 1.773 filas — exactamente el tipo de rotura silenciosa contra la que el
> encargo pide tests.

Coordenadas: las 1.149 paradas caen dentro de la caja geográfica de Vigo. Cero atípicas.

### 2.4 Frescura y el malentendido de "enero de 2024"

El handoff señalaba que la metadata del portal decía "última actualización 29 enero 2024" y lo
daba como probable causa raíz del fallo con Google. **Los datos no respaldan esa conclusión.**

Consulté el registro de CKAN:

```
GET https://datos-ckan.vigo.org/api/3/action/package_show?id=gtfs-vitrasa
```

```
title             GTFS de Vitrasa. Autobús público urbano
license           Open Data Commons Attribution License | odc-by
metadata_created  2023-12-18T12:10:48
metadata_modified 2024-01-29T07:31:01     <-- el "enero 2024" del handoff
frequency         None                     <-- la cadencia P1D NO está declarada aquí
recurso ZIP: last_modified = None, url = https://datos.vigo.org/data/transporte/gtfs_vigo.zip
```

`metadata_modified` es **la fecha de la última edición de la ficha del catálogo**, no del dato.
La ficha se creó en diciembre de 2023, se retocó en enero de 2024 y nadie la ha tocado desde
entonces. El ZIP al que apunta, en cambio, se regeneró el **2026-08-31**. Además, el recurso
tiene `last_modified: None`, así que CKAN no expone ninguna fecha de dato — solo la de la ficha.

**Corrección al handoff:** el feed no está caducado. La cadencia declarada "diaria (P1D)"
tampoco aparece en el CKAN actual (`frequency: None`), y el patrón observado no es diario sino
**semanal**: generado el domingo 31 de agosto para cubrir la semana del 1 al 7 de septiembre.

### 2.5 El defecto real del feed: ventana de calendario de 7 días

Aquí está el problema de verdad, y no es el que se esperaba.

- **`calendar.txt` está vacío** (solo la cabecera). Todo el servicio se define vía
  `calendar_dates.txt`. Esto es GTFS válido (patrón "calendar_dates-only"), no un error.
- **`calendar_dates.txt` cubre exactamente 7 días: `20260901` … `20260907`.**
- Las 632 filas son **todas `exception_type=1`** (servicio añadido). No hay una sola supresión.
- 223 `service_id` distintos.

Cobertura por día (hoy = viernes 2026-09-04, dentro de la ventana):

| Fecha | Día | Servicios | Viajes |
|---|---|---:|---:|
| 20260901 | Mar | 103 | 1.660 |
| 20260902 | Mié | 103 | 1.660 |
| 20260903 | Jue | 103 | 1.660 |
| **20260904** | **Vie** | **105** | **1.684** |
| 20260905 | Sáb | 64 | 1.104 |
| 20260906 | Dom | 51 | 788 |
| 20260907 | Lun | 103 | 1.660 |

Hoy: **105 servicios activos, 1.684 viajes, 43 rutas, 63.733 `stop_times`.**

> **El feed caduca el 2026-09-07, dentro de 3 días.**

**Esta es, con mucha más probabilidad que la frescura, la causa del fallo con Google Transit.**
Un feed cuyo servicio termina siempre dentro de 7 días está permanentemente en estado
"expirando/expirado" para los validadores de Google, que esperan un horizonte futuro
razonable (del orden de 30 días o más). Sumado a la ausencia de `feed_info.txt` (sin
`feed_start_date`, `feed_end_date` ni `feed_version`) y al `calendar.txt` vacío, el feed es
técnicamente correcto pero **inadecuado para un consumidor externo que lo indexa
periódicamente**. Para nosotros, que lo re-descargamos bajo demanda, es perfectamente usable.

**Consecuencia de diseño (la más importante de toda la Fase 0):** el importador no puede
tratar el GTFS como un recurso que se descarga una vez. Tiene que:
1. Comprobar `ETag`/`Last-Modified` con frecuencia (al menos al arrancar y una vez al día).
2. Saber en qué fecha caduca el feed importado y **decírselo al usuario en pantalla** cuando
   los horarios teóricos pidan una fecha fuera de la ventana cubierta.
3. No confundir "no hay servicio ese día" con "ese día está fuera de mi ventana de datos".

### 2.6 Red: rutas y paradas

- **59 rutas** en `routes.txt`, todas `route_type=3` (autobús). **43 tienen viajes**; **16 no
  tienen ninguno**.
- **1.149 paradas**, todas servidas.
- **3.630 viajes**, **135.809 `stop_times`**.
- `agency.txt`: `Viguesa de Transportes S.L.`, `Europe/Madrid`, `es`.

Las 16 rutas sin viajes son entradas muertas o variantes estacionales:

```
U1  LANZADEIRA PZA. AMÉRICA – UNIVERSIDADE      11.  G. VÍA Y P. ESPAÑA
U2  LANZADEIRA PZA. DE ESPAÑA – UNIVERSIDADE    15B. POR T. PAREDES
U1B GARRIDA                                     15A. GRILEIRA-CAEIRO
LZD. PSA  STELLANTIS                            4A-  COIA-POULO
N1  SAMIL - BUENOS AIRES                        4A.  POULO-ARAGÓN
MARISQUIÑO  SAMIL - TRAVESIA VIGO               5A.  NAVIA-TRV. DE VIGO
R   L8 R                                        5B.  NAVIA-S. BADÍA
                                                6.   BOUZAS
                                                9B.  BOUZAS
```

Nótese el patrón de **nombres duplicados con punto final** (`11` vs `11.`, `4A` vs `4A.` vs
`4A-`, `6` vs `6.`). Son variantes de refuerzo; las versiones con punto no tienen viajes en
esta semana. **La UI debe filtrar las rutas sin viajes**, o aparecerán "líneas fantasma" —
justo el defecto que el handoff reprocha a la app oficial.

Comparación con las cifras del handoff (hueco de información #7): el handoff citaba
"127 buses / 45 líneas" (Wikipedia) y "116 buses" (Concello). El GTFS dice **43 líneas con
servicio real** esta semana, cifra compatible con "45 líneas".

### 2.7 Anomalías menores de formato a manejar en el parser

Observadas directamente en los ficheros:

1. **`calendar.txt` tiene espacios tras las comas en la cabecera**
   (`service_id, monday, tuesday, …`). Un parser CSV estricto generaría columnas llamadas
   `" monday"`. Hay que hacer `trim` de los nombres de columna. (Aquí es inocuo porque el
   fichero no tiene filas, pero el día que las tenga rompería.)
2. **Los `service_id` contienen espacios dobles**: `A  01LP001_008001`. No se pueden tratar
   como tokens sin espacios.
3. **Hay un tabulador dentro de un `route_long_name`**: la ruta `18A` empieza por `\t`
   (`"\tAREAL/COLÓN - SÁRDOMA/POULEIRA"`). Hay que hacer `trim` de los valores.
4. **Nombres de parada con espacios dobles**: `Praza de América  1`, `Rúa da Coruña  26`.
   Cuidado al normalizar para búsqueda.
5. Los ficheros no llevan BOM, pero conviene leer con `utf-8-sig` por si acaso.

### 2.8 `stop_id` vs `stop_code` — el detalle que rompe la integración

**Este es el hallazgo operativo más importante de la Fase 0.** Las paradas tienen dos
identificadores distintos y **no son intercambiables**:

| Campo GTFS | Ejemplo | Uso |
|---|---|---|
| `stop_id` | `3493` | Clave interna del GTFS. Es la que enlaza con `stop_times`. |
| `stop_code` | `P006930` | Código público de la parada. |

La API de tiempo real **no usa `stop_id`**. Usa la **parte numérica de `stop_code` sin la `P`
y sin ceros a la izquierda**: `P006930` → `6930`.

Lo descubrí de la peor forma posible: mis primeras tres llamadas a la API con
`id=3493`, `id=3885`, `id=3688` (los `stop_id` del GTFS) devolvieron **`{"parada":[],
"estimaciones":[]}` con HTTP 200** — un fallo silencioso, sin error. Solo al descargar el
catálogo de paradas del Concello y cruzarlo con el GTFS quedó clara la correspondencia.

**Validación del cruce (las 1.149 paradas, sin excepciones):**

| Comprobación | Resultado |
|---|---|
| Paradas en GTFS / en la API | 1.149 / 1.149 |
| `stop_id` presentes en ambos | **1.149** (0 solo en GTFS, 0 solo en la API) |
| `int(stop_code sin "P")` == `id` de la API | **1.149 / 1.149 coincidencias, 0 discrepancias** |
| Nombres idénticos carácter a carácter | **1.149 / 1.149** |
| Paradas a más de 25 m entre ambas fuentes | **0** |

La correspondencia es exacta y total. Esto además demuestra algo relevante: **el GTFS y la API
de tiempo real salen del mismo sistema operacional**, no de dos exportaciones desacopladas.
Refuerza la confianza en la frescura del GTFS.

> **Consecuencia de diseño:** la tabla `stops` debe guardar los dos identificadores, y la capa
> de red **debe** consumir el derivado de `stop_code`. Si se pasa un `stop_id` por error, la
> app no dará un error: mostrará una parada vacía. Merece un tipo distinto en Swift
> (`StopID` vs `VitrasaStopCode`) para que el compilador impida confundirlos.

---

## 3. Tiempo real: API del Concello (fuente primaria)

### 3.0 Geocodificación de direcciones: Apple Maps / MapKit

La búsqueda de direcciones usa `MKLocalSearchCompleter` y `MKLocalSearch`, sin claves de API,
cuentas ni una dependencia nueva. Solo se manda a Apple el texto que el usuario escribe y una
región fija centrada en Vigo; **nunca** se manda la ubicación actual. La región fija conserva la
promesa de privacidad de `Info.plist` y es suficientemente amplia para Vigo y la red próxima.
La aplicación resuelve una sugerencia solo cuando se toca, no cada resultado mientras se escribe.

Extraída del código de **ambos** proyectos de referencia y verificada con `curl`.

### 3.1 Endpoint

```
GET https://datos.vigo.org/vci_api_app/api2.jsp
```

Parámetros para llegadas:

| Parámetro | Valor | Notas |
|---|---|---|
| `tipo` | `TRANSPORTE-ESTIMACION-PARADA` | **Con guiones**, a diferencia de los demás `tipo` que usan guion bajo |
| `id`   | p.ej. `6930` | La parte numérica de `stop_code`, **no** el `stop_id` (ver §2.8) |
| `ttl`  | `5` | VigoBusAPI usa `5`, infobus-bot usa `1`. No observé diferencia en la respuesta |

### 3.2 Codificación — trampa confirmada

```
Content-Type: application/json;charset=ISO-8859-1
```

La respuesta es **ISO-8859-1 (Latin-1), no UTF-8**, y lo declara en la cabecera. Está
confirmado por triplicado:
1. La cabecera `Content-Type` observada en vivo.
2. `infobus-bot` la decodifica explícitamente: `Encoding.GetEncoding("ISO-8859-1")`.
3. `VigoBusAPI` mantiene una tabla de reparación de mojibake (`Ã¡`→`á`, `Ã©`→`é`, `Ã±`→`ñ`…),
   que es justo el síntoma de haber decodificado Latin-1 como UTF-8.

> **Consecuencia:** en Swift hay que decodificar con `String.Encoding.isoLatin2015`/
> `.isoLatin1` antes de pasar a `JSONDecoder`, **no** usar `JSONDecoder` directamente sobre los
> bytes. Si se hace lo segundo, o falla el decode o salen "Praza de AmÃ©rica".

### 3.3 Respuesta — capturas literales

Parada 6930 (Praza de América 1), 2026-09-04 04:39 CEST:

```json
{"parada":[{"latitud":42.220997313,"longitud":-8.732835177,"stop_vitrasa":6930,"nombre":"Praza de América  1"}],
 "estimaciones":[
   {"minutos":29,"ruta":"P. AMERICA - URZAIZ - G.ESPINO*","linea":"N4","metros":-1},
   {"minutos":141,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1},
   {"minutos":158,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1},
   {"minutos":166,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1},
   {"minutos":176,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1}]}
```

Parada 14264 (Rúa de Urzáiz – Príncipe):

```json
{"parada":[{"latitud":42.235873545,"longitud":-8.720083317,"stop_vitrasa":14264,"nombre":"Rúa de Urzáiz - Príncipe"}],
 "estimaciones":[
   {"minutos":9,"ruta":"PRAZA AMÉRICA*","linea":"C1","metros":-1},
   {"minutos":39,"ruta":"PEINADOR - AEROPORTO*","linea":"A","metros":-1},
   {"minutos":39,"ruta":"P. AMERICA - URZAIZ - G.ESPINO*","linea":"N4","metros":-1},
   {"minutos":42,"ruta":"XESTOSO *","linea":"15B","metros":-1},
   {"minutos":46,"ruta":"POULO - ARAGÓN por URZÁIZ*","linea":"4A","metros":-1}]}
```

Parada 8750 (Rúa de Urzáiz – Est. Intermodal – C.C.):

```json
{"parada":[{"latitud":42.233722977,"longitud":-8.714502762,"stop_vitrasa":8750,"nombre":"Rúa de Urzáiz - Est. Intermodal - C.C."}],
 "estimaciones":[
   {"minutos":15,"ruta":"4 STELLANTIS por CAMELIAS*","linea":"PSA","metros":-1},
   {"minutos":54,"ruta":"SAMIL por BERBES *","linea":"15B","metros":-1},
   {"minutos":59,"ruta":"P. SANZ - BALAIDOS - NAVIA*","linea":"N4","metros":-1},
   {"minutos":70,"ruta":"BOUZAS por BEIRAMAR*","linea":"6","metros":-1},
   {"minutos":76,"ruta":"  COIA por CAMELIAS*","linea":"4A","metros":-1}]}
```

### 3.4 Esquema

```
{
  "parada": [                       // 0 o 1 elemento
    { "stop_vitrasa": Int,          // el id que pediste (= stop_code numérico)
      "nombre":       String,
      "latitud":      Double,
      "longitud":     Double }
  ],
  "estimaciones": [
    { "linea":   String,            // nombre corto de línea, p.ej. "C1", "N4", "15B", "PSA"
      "ruta":    String,            // destino/itinerario, sucio (ver §3.6)
      "minutos": Int,               // minutos hasta el paso
      "metros":  Int }              // distancia del bus a la parada; -1 = desconocida
  ]
}
```

### 3.5 Comportamiento en errores — importante

- **Parada inexistente (`id=999999`): HTTP 200 con `{"parada":[],"estimaciones":[]}`.**
  No hay 404. Es indistinguible de "parada válida sin buses". La única forma de diferenciarlas
  es comprobar si `parada` está vacío: si `parada` viene vacío, el `id` no existe; si
  `parada` viene relleno y `estimaciones` vacío, la parada existe pero no hay pasos previstos.
- **`tipo` desconocido:** HTTP 200 con `{"t": "TIPO_INVALIDO <valor>"}`. Tampoco es un error HTTP.

> **Consecuencia:** la capa de red **nunca** debe fiarse del código HTTP para detectar fallos.
> Hay que inspeccionar el cuerpo. Un `guard response.statusCode == 200` no protege de nada aquí.

### 3.6 Suciedad en los datos, observada literalmente

- **`ruta` termina en `*`** en todos los casos observados. Hay que recortarlo.
- **Espacios sobrantes**: `"XESTOSO *"`, `"  COIA por CAMELIAS*"` (dos espacios iniciales).
- **`linea` no siempre coincide con el `route_short_name` del GTFS.** La API devuelve `PSA`
  donde el GTFS tiene `PSA1`/`PSA4`; y el catálogo de paradas usa `PSA 1`/`PSA 4` (con espacio).
  Cruce de los nombres de línea del catálogo de paradas contra el GTFS:
  - En la API pero no en el GTFS: `PSA 1`, `PSA 4`
  - En el GTFS pero no en la API: `11.`, `15A.`, `15B.`, `4A-`, `4A.`, `5A.`, `5B.`, `6.`,
    `9B.`, `LZD`, `LZD. PSA`, `MARISQUIÑO`, `PSA1`, `PSA4`, `R`, `U1`, `U1B`, `U2`
    (es decir: exactamente las 16 rutas sin viajes, más las variantes con punto)
- `VigoBusAPI` documenta además que algunas letras de línea vienen pegadas a la `ruta`
  (`"A"`, `"B"`, `"C"` con comillas o espacios al inicio) y hay que moverlas a `linea`.
  **No observé este caso en mis tres muestras**, pero está en su código y conviene defenderse.

> **Consecuencia:** el emparejado línea-de-tiempo-real ↔ ruta-GTFS debe ser **difuso y
> tolerante a fallo**: normalizar (trim, quitar `*`, colapsar espacios, quitar punto final) e
> intentar casar; si no casa, **mostrar igualmente la llegada** con lo que diga la API. Nunca
> descartar una llegada real porque no encontramos su ruta en el GTFS.

### 3.7 El campo `metros` y la distinción tiempo real / teórico

`metros` es la distancia del autobús a la parada. **En las 15 estimaciones que capturé, el
valor fue `-1` en todas.** Las capturas se hicieron a las 04:39–04:45 CEST, y el primer paso
del GTFS es a las `05:00:00`: **no había ningún autobús en circulación**, así que todas las
estimaciones eran necesariamente teóricas.

**Hipótesis (NO verificada):** `metros == -1` significa "sin vehículo localizado" → la
estimación es horario teórico; `metros >= 0` significa que hay un bus real con posición
conocida → estimación de tiempo real del SAE. Si se confirma, es exactamente la señal que la
app necesita para cumplir el requisito de "distinguir siempre tiempo real de teórico".

Refuerza la hipótesis que `minutos` llegue a 176 (casi 3 horas): ningún sistema de localización
predice a 3 horas vista; eso solo puede salir del horario planificado.

**Pendiente:** volver a muestrear en hora punta y comprobar si aparecen `metros >= 0`.
Hasta confirmarlo, la app debe tratar **toda** estimación como "no confirmada como tiempo real".

**Remuestreo del 2026-09-13, 13:45–13:50 CEST (domingo, en servicio).** En las paradas 7270,
6930, 14264 y 8750, **todas** las estimaciones traían `metros >= 0`. Los valores van de 877 m a
36.324 m; en la 7270, un 15C a 129 min marcaba 36.324 m. La hipótesis se confirma solo en parte:
`metros >= 0` significa que la fuente tiene un vehículo asignado a esa pasada, **no** que esté
cerca ni que la estimación sea fina. A 129 minutos, ese vehículo aún tiene que dar una vuelta
entera. Además, las estimaciones sí corrigen el horario: la línea 11 iba a 23 min en el GTFS y a
26–27 min en vivo, y un 11 que el horario ponía a las 14:42 no aparecía en vivo.

### 3.8 Otros `tipo` disponibles en `api2.jsp` (verificados en vivo)

| `tipo` | Devuelve | Verificado |
|---|---|---|
| `TRANSPORTE-ESTIMACION-PARADA` | Llegadas de una parada (`&id=`&`ttl=`) | Sí |
| `TRANSPORTE_PARADAS` | Catálogo completo: 1.149 paradas con líneas | Sí |
| `TRANSPORTE_PARADA_ID` | Una parada (`&id=`) | Sí |
| `TRANSPORTE_TIPO_DIA` | Tipo de día de hoy → `[{"tipo_dia":"L"}]` | Sí |
| `TRANSPORTE_LINEAS_SERVICIOS` | Líneas con color, tipo e imagen | Sí |
| `TRANSPORTE_CAJEROS` | Cajeros de recarga de tarjeta | No probado |
| `TRANSPORTE_CONTACTO` | Puntos de contacto | No probado |
| `TRANSPORTE_TARIFAS_ES` / `_GL` / `_EN` | Tarifas | No probado |

Muestra de `TRANSPORTE_PARADAS`:

```json
{"lineas":"C1, N4","stop_id":"3493","lon":-8.732835177,"id":6930,
 "nombre":"Praza de América  1","lat":42.220997313}
```

> Ojo: aquí `stop_id` (String) es el `stop_id` del GTFS y `id` (Int) es el código de
> tiempo real. Los nombres van al revés de lo que uno esperaría. Ver §2.8.

Muestra de `TRANSPORTE_LINEAS_SERVICIOS`:

```json
{"descripcion":"Universidade - Aeroporto","subtipo_ga":"Aeroporto","tipo":"AEROPUERTO",
 "color":"#77298F","imagen":"Termómetro Línea A.png","subtipo_es":"Aeropuerto","linea":"A"}
```

**Dos discrepancias entre el código de referencia y la respuesta real** (el código C# está
desactualizado; me guié por lo observado, no por él):
- `infobus-bot` espera `subtipo_gl`; la API devuelve **`subtipo_ga`**.
- `infobus-bot` mapea `TipoDia.Tipo`; la API devuelve la clave **`tipo_dia`**.

Imágenes de línea: `https://www.vitrasa.es/FotosFichas/lineas14/<imagen>` (no verificado).

---

## 4. Tiempo real: InfoBus HTML (fuente secundaria / respaldo)

```
GET http://infobus.vitrasa.es:8002/Default.aspx?parada=6930
GET http://infobus.vitrasa.es/Default.aspx?parada=6930      (mismo contenido, puerto 80)
```

**Ambas responden HTTP 200, 8.327 bytes.** `Server: Apache`,
`Content-Type: text/html; charset=utf-8`. Usa el **mismo espacio de identificadores** que la
API JSON (`parada=6930`, o sea el `stop_code` numérico).

### 4.1 La página fue rediseñada: los parsers de VigoBusAPI ya no sirven

`VigoBusAPI` (último commit **enero de 2023**) parsea filas mediante estilos en línea de
ASP.NET WebForms:

```python
{"name": "tr", "attrs": {"style": "color:#333333;background-color:#F7F6F3;"}}
{"name": "tr", "attrs": {"style": "color:#284775;background-color:White;"}}
```

**Ese marcado ya no existe.** El HTML actual usa clases CSS:

```html
<span id="lblParada" class="label-parada">6930</span>
<span id="lblHora"   class="label-hora">Hora: 04:39</span>
<span id="lblNombre" class="label-nombre">Praza de AmÃ©rica, 1</span>
<td class="col-linea"   align="left"  width="15%">N4</td>
<td                     align="left"  width="75%">P. AMERICA - URZAIZ - G.ESPINO*</td>
<td class="col-minutos" align="right" width="10%">28</td>
```

Lo que **sí** sobrevive: los `id` de los `<span>` (`lblParada`, `lblNombre`), el `id`
`GridView1` de la tabla, y los campos `__VIEWSTATE` (siguen presentes). Lo que **no**
sobrevive son los selectores de fila por estilo en línea.

### 4.2 Codificación rota en el HTML

La página se declara `charset=utf-8` pero sirve mojibake: `Praza de AmÃ©rica, 1`. Y mezcla
codificaciones: en unas celdas usa mojibake (`AmÃ©rica`) y en otras entidades HTML
(`AM&#201;RICA`). Es decir, texto Latin-1 servido como UTF-8. Hay que reparar el mojibake
**y** decodificar entidades.

### 4.3 Comparación con la API JSON

Mismos datos y mismo orden (28 min en HTML vs 29 min en JSON, medidos con un minuto de
diferencia). El bonus del HTML es `lblHora` ("Hora: 04:39"), el reloj del servidor, útil para
detectar respuestas rancias. La API JSON es más limpia, más barata y trae `metros`.

**Decisión:** la API JSON es la fuente primaria. El HTML queda documentado como respaldo, pero
**requeriría escribir un parser nuevo**; el de VigoBusAPI no vale. No se implementa en Fase 1.

### 4.4 Límite de resultados

Tanto la API JSON como el HTML devolvieron **exactamente 5 estimaciones** en las tres paradas
probadas. El HTML tiene paginación (`__VIEWSTATE` + `__EVENTTARGET=GridView1`) para ver más.
No pude determinar si 5 es un tope duro o simplemente eran los buses previstos; a las 04:40
con un solo servicio nocturno activo, es plausible que fuera todo lo que había.

**Resuelto el 2026-09-13, en servicio.** Las 5 filas son **el tamaño de página del HTML**, no un
tope de la fuente. La API JSON no tiene tope observado y trae unas dos pasadas por línea:

| Parada | Filas en la API JSON | InfoBus HTML |
|---|---:|---|
| 7270 | 7 | 5 en la página 1 y 2 en la página 2 (`__EVENTARGUMENT=Page$2`), las mismas |
| 14264 | 19 | 5 por página |
| 8750 | 14 | 5 por página |
| 6930 | 2 | 2, sin paginar |

Los minutos coinciden fila a fila entre las dos fuentes, con ±1 min según el segundo en que se
consulta cada una. Es decir, InfoBus (la web a la que lleva el QR de cada poste) y la app
enseñan **los mismos datos**. La app los ve todos de una vez.

---

## 5. Otros datasets del Concello

| Dataset | URL | Estado |
|---|---|---|
| Paradas (JSON) | `https://datos.vigo.org/data/transporte/paradas.json` | Citado por infobus-bot; no probado (usé el `tipo=TRANSPORTE_PARADAS` de la API, equivalente) |
| Navieras | `https://datos.vigo.org/data/trafico/navieras.json` | **Verificado** — ver §6 |
| CKAN API | `https://datos-ckan.vigo.org/api/3/action/package_show?id=…` | **Verificado**, funciona |

Sobre el hueco de información #4 del handoff (estabilidad de URLs): **los dos dominios están
vivos y tienen roles distintos**. `datos-ckan.vigo.org` es el catálogo (metadata, API CKAN);
`datos.vigo.org` sirve los datos y la API de aplicación. No son alternativas: se usan ambos.

---

## 6. Ferry de la ría — **no verificado, y esto es un problema**

El handoff anticipaba que no habría dato estructurado. **Se confirma, y de hecho es peor de lo
esperado: tampoco pude extraer los horarios de forma fiable desde la web.**

### 6.1 Lo que sí está verificado

El dataset del Concello `https://datos.vigo.org/data/trafico/navieras.json` responde y contiene
**4 registros**, con **cero información de horarios** — solo dirección y teléfono, exactamente
como decía el handoff:

```json
{"barrio":"VIGO","codigo_postal":"36202","numero":0,"web":null,
 "calle":"RUA CANOVAS DEL CASTILLO","parroquia":"VIGO","lon":-8.72523,"id":410,
 "telefono":"986433370","nombre":"Naviera De Las Rías Gallegas","lat":42.24075}
```

Claves disponibles: `barrio, calle, codigo_postal, id, lat, lon, nombre, numero, parroquia,
telefono, web`. **No hay `horario`, ni `ruta`, ni `salidas`.**

Las cuatro navieras:

| Nombre | Teléfono | Web | Ubicación |
|---|---|---|---|
| Naviera De Las Rías Gallegas | 986433370 | *(null)* | Rúa Cánovas del Castillo (42.24075, -8.72523) |
| Naviera Mar de Ons | 986225272 | https://www.mardeons.es | Rúa Cánovas del Castillo (42.24023, -8.72529) |
| Nabia Naviera | 986320048 | www.piratasdenabia.com | Rúa Cánovas del Castillo (42.24122, -8.72466) |
| Cruceros Rías Baixas | 986731343 | http://crucerosriasbaixas.com | Rúa Montero Ríos (42.24056, -8.7258) |

> Nota: el handoff nombra "Rías Gallegas"; su web real es **`rgnaviera.com`**, y el dataset del
> Concello tiene el campo `web` a `null` para esa naviera.

### 6.2 Lo que NO pude obtener, y exactamente por qué

**No he conseguido ni un solo horario de salida verbatim y atribuible.** Detalle por fuente:

| Fuente | URL probada | Qué observé |
|---|---|---|
| Mar de Ons | `https://www.mardeons.com/es/horarios/` | **301** → `https://www.mardeons.es/es/horarios/` |
| Mar de Ons | `https://www.mardeons.es/es/horarios/` | **404** ("Uuups! Lo sentimos, la página que buscas no se ha podido encontrar"). La ruta correcta es `/precios-y-horarios/` |
| Mar de Ons | `https://www.mardeons.es/precios-y-horarios/` | Página correcta. Se ven los **encabezados** de las tablas ("Lunes a viernes no festivos", "Sábados", "Domingos y festivos", "Julio y Agosto") pero **las celdas con las horas no se extraen como texto**. Aviso en la propia página: *"El calendario y horarios son susceptibles de ser modificados ampliando según demanda"*. **No aparece ninguna ruta Vigo–Moaña**, solo Vigo–Cangas y Vigo–Isla de San Simón |
| Piratas de Nabia | `https://piratasdenabia.com/horarios/` | Solo tarifas (adultos 2,40 €; tarjeta metropolitana 0,90–1,34 €). El horario es **una imagen** llamada `linea-moana-vigo-2024` — **y el nombre del fichero dice 2024** |
| Rías Gallegas | `https://rgnaviera.com/es/` | Solo horarios de **Cíes** (Vigo→Cíes 11:00 y 15:30; Cíes→Vigo 14:15 y 17:40; Cangas→Cíes 10:30 y 15:00). **Ningún horario de la línea regular Vigo–Cangas.** Sin días de la semana ni vigencia |

Información de contexto (de prensa/turismo, **no** de fuente primaria, **no** usable como dato):
frecuencia de media hora de lunes a viernes y horaria los fines de semana y festivos en
Vigo–Cangas, con travesía de unos 20 minutos. **Esto es prosa, no un horario. No lo voy a
convertir en datos.**

### 6.3 Conclusión sobre el ferry

Los horarios de ferry **no están disponibles de forma estructurada ni extraíbles de forma
fiable por web**. Viven en imágenes y tablas renderizadas por JavaScript, y al menos una de
ellas (Piratas de Nabia) parece llevar sin actualizarse desde 2024 a juzgar por el nombre del
fichero.

**No he inventado ni aproximado ningún horario.** La Fase 2 requerirá transcribirlos a mano
desde las webs abiertas en un navegador real, o fotografiando los horarios en el muelle. Esto
refuerza dos decisiones que el handoff ya contemplaba y que ahora son obligatorias:
- Los horarios de ferry serán un **JSON versionado en el bundle, mantenido a mano**.
- La UI **debe** mostrar la fecha de última actualización manual y avisar cuando envejezca.

---

## 7. Qué NO pude verificar, y por qué

| # | Punto | Motivo |
|---|---|---|
| 1 | **Horarios de ferry** de las tres navieras (Fase 0, punto 5) | Están en imágenes y tablas generadas por JavaScript. Ver §6.2 para el detalle exacto de cada URL y lo que devolvió. **Es el único punto de la Fase 0 que queda incompleto.** |
| 2 | Significado real de `metros` | A las 04:40 no circulaba ningún autobús, así que las 15 muestras dieron `-1`. Hay que remuestrear en hora de servicio. Ver §3.7 |
| 3 | Si 5 estimaciones es un tope duro | Solo pude medir en horario nocturno, con muy poco servicio. Ver §4.4 |
| 4 | Validación con el validador de MobilityData | No está instalado en el entorno y no quise añadir una dependencia (Java/Docker) por esto. Sustituido por validación propia que cubre lo que pide el handoff. Ver §2.3 |
| 5 | WSDL de Vitrasa (hueco #3 del handoff) | No lo probé: la API JSON funciona y es mejor. `abdonrd/time-for-vbus-api` no se llegó a consultar |
| 6 | `tipo` = `TRANSPORTE_CAJEROS`, `_CONTACTO`, `_TARIFAS_*` | Fuera del alcance de la Fase 1 |
| 7 | Imágenes de línea en `vitrasa.es/FotosFichas/lineas14/` | No probado |
| 8 | Que la ventana del GTFS se renueve de verdad | Solo tengo una instantánea. Hay que volver a mirar después del 2026-09-07 para confirmar que se regenera. **Si no se renovara, el feed caduca y pasaríamos al escenario B** |

---

## 8. Consecuencias para el diseño (resumen accionable)

1. **`stop_code`, no `stop_id`, para la red.** Tipos Swift distintos para que no se puedan
   confundir. Un error aquí no da error: da una pantalla vacía. (§2.8)
2. **Decodificar ISO-8859-1 antes del JSON.** (§3.2)
3. **No fiarse del código HTTP.** Éxito y fracaso son ambos HTTP 200; hay que mirar el cuerpo.
   `parada` vacío = la parada no existe. (§3.5)
4. **Las horas del GTFS son segundos desde el inicio del día de servicio**, no horas de reloj:
   1.773 filas superan las 24 h y llegan a `30:31:00`. (§2.3)
5. **El feed caduca cada 7 días.** Refresco condicional por `ETag` y aviso en pantalla cuando
   se pidan horarios fuera de la ventana cubierta. (§2.5)
6. **Filtrar las 16 rutas sin viajes** o saldrán líneas fantasma. (§2.6)
7. **Emparejado difuso** entre líneas de tiempo real y rutas del GTFS, y **nunca descartar** una
   llegada real por no encontrar su ruta. (§3.6)
8. **Hacer `trim` de nombres de columna y de valores** al parsear el CSV. (§2.7)
9. **Hasta confirmar `metros`, ninguna estimación puede etiquetarse como tiempo real
   confirmado.** (§3.7)

---

## 9. Atribución

- **GTFS y datasets del Concello de Vigo** — Open Data Commons Attribution License (ODC-BY).
  Requiere atribución al **Concello de Vigo**.
- **`David-Lor/VigoBusAPI`** (Apache-2.0) — de aquí salen el endpoint `api2.jsp`, el endpoint
  HTML de InfoBus, la pista de la codificación (vía su tabla de mojibake) y las correcciones
  de nombres de línea y parada.
- **`arielcostas/infobus-bot` / `Costasdev.VigoTransitApi`** — de aquí salen la confirmación de
  `ISO-8859-1`, el catálogo de valores de `tipo`, y los nombres exactos de los campos JSON.

Ambos proyectos merecen figurar en la pantalla de "Fuentes de datos" de la app.

---

## 10. Cómo reproducir esta verificación

```bash
# 1. GTFS: descarga y cabeceras
curl -sSL -D headers.txt -o gtfs_vigo.zip \
  -A "ILoveVigoRoutes/0.1 (personal use)" \
  https://datos.vigo.org/data/transporte/gtfs_vigo.zip
unzip -l gtfs_vigo.zip     # fechas internas

# 2. Metadata del catálogo (ojo: fecha de la FICHA, no del dato)
curl -sS "https://datos-ckan.vigo.org/api/3/action/package_show?id=gtfs-vitrasa"

# 3. Tiempo real. OJO: id = stop_code numérico, NO stop_id
curl -sS "https://datos.vigo.org/vci_api_app/api2.jsp?tipo=TRANSPORTE-ESTIMACION-PARADA&id=6930&ttl=5" \
  | iconv -f ISO-8859-1 -t UTF-8

# 4. Catálogo de paradas (para el cruce stop_id <-> stop_code)
curl -sS "https://datos.vigo.org/vci_api_app/api2.jsp?tipo=TRANSPORTE_PARADAS" \
  | iconv -f ISO-8859-1 -t UTF-8

# 5. InfoBus HTML (respaldo)
curl -sS "http://infobus.vitrasa.es:8002/Default.aspx?parada=6930" | iconv -f ISO-8859-1 -t UTF-8
```
