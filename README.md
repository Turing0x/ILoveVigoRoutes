# ILoveVigoRoutes

App iOS nativa en SwiftUI para consultar el transporte público de Vigo — autobuses de Vitrasa y
ferry de la ría.

**Proyecto personal, de uso estrictamente personal.** No se distribuye, no se publica, no lleva
cuentas, publicidad ni telemetría de ningún tipo.

La especificación autoritativa es [`ILoveVigoRoutes-HANDOFF.md`](ILoveVigoRoutes-HANDOFF.md).
La verificación de fuentes está en [`DATA-SOURCES.md`](DATA-SOURCES.md).

---

## Decisión sobre la estrategia de GTFS (§5 del handoff)

> **Escenario elegido: A — el GTFS está actualizado.**
> Con una salvedad importante que altera el diseño del importador: **el feed solo cubre 7 días**.

Decidido el **2026-09-04** con los datos recogidos en la Fase 0. El detalle completo, con las
respuestas literales, está en [`DATA-SOURCES.md`](DATA-SOURCES.md).

### Los datos que sostienen la decisión

**1. El feed está fresco.** El ZIP responde con `Last-Modified: Mon, 31 Aug 2026 04:31:47 GMT`
— cuatro días antes de la verificación — y los ocho ficheros internos llevan todos esa misma
fecha. No hay nada de 2024 dentro del ZIP.

**2. El "enero de 2024" del handoff era una lectura equivocada de la metadata.** El campo
`metadata_modified: 2024-01-29` del catálogo CKAN es **la fecha de la última edición de la
ficha del catálogo**, no del dato. La ficha lleva sin tocarse desde enero de 2024; el fichero al
que apunta se regenera cada semana. El recurso ni siquiera expone fecha de dato
(`last_modified: None`). La hipótesis del handoff de que un GTFS rancio era la causa del fallo
con Google **no se sostiene**.

**3. El feed es estructuralmente impecable.** Validación propia sobre lo que pide el handoff:

- Integridad referencial: **0 errores** en las seis comprobaciones
  (`trips`→`routes`, `trips`→`calendar`, `trips`→`shapes`, `stop_times`→`trips`,
  `stop_times`→`stops`, y viajes sin paradas).
- Formatos de hora: **0 malformados**, 0 vacíos, 0 secuencias no monótonas.
- 0 paradas nunca servidas, 0 shapes huérfanos, 0 coordenadas fuera de Vigo.
- `shapes.txt` **presente y completo**: 139.611 puntos, 226 trazados, todos referenciados.
  (Resuelve el hueco de información #5 del handoff.)

**4. Hay servicio activo hoy.** Para el 2026-09-04: **105 servicios, 1.684 viajes, 43 rutas,
63.733 `stop_times`**. La red es de 1.149 paradas y 59 rutas (43 con servicio real).

**5. El GTFS y la API de tiempo real son el mismo sistema.** Las 1.149 paradas del GTFS y las
1.149 del catálogo del Concello coinciden **una a una**: mismos identificadores, nombres
idénticos carácter a carácter, y ninguna a más de 25 m de distancia entre ambas fuentes. Un
GTFS abandonado no coincidiría así con el sistema que sirve el tiempo real.

Nada de esto es compatible con el escenario B (caducado) ni con el C (roto).

### La salvedad: ventana de 7 días

`calendar.txt` está **vacío** (solo cabecera) y todo el servicio se define en
`calendar_dates.txt`, que cubre exactamente **`20260901` … `20260907`**. El feed importado hoy
**caduca el 2026-09-07**.

Esto es GTFS válido — el patrón "calendar_dates-only" es legítimo — pero significa que el
importador **no puede** tratar el GTFS como algo que se descarga una vez y se olvida.

De paso, es la explicación mucho más probable del fallo con Google Transit que la que suponía
el handoff: un feed cuyo servicio termina siempre dentro de 7 días está permanentemente en
estado "expirando" para un indexador externo, que espera un horizonte del orden de 30 días.
Sumado a la ausencia de `feed_info.txt` y al `calendar.txt` vacío, el feed es correcto pero
inadecuado para quien lo consume periódicamente desde fuera. Para nosotros, que lo
re-descargamos bajo demanda, sirve perfectamente.

### Qué implica para el importador

Se implementa el escenario A —importación directa del GTFS como fuente de verdad para
topología **y** horarios teóricos— con tres refuerzos que el escenario A puro no contemplaba:

1. **Refresco condicional como pieza de primera clase**, no como adorno: `ETag` e
   `If-Modified-Since` contra el ZIP, comprobado al arrancar y como mucho una vez al día.
2. **La base de datos guarda la ventana de validez del feed** (fecha mínima y máxima de
   `calendar_dates`), y la UI **avisa en pantalla** cuando se piden horarios de una fecha fuera
   de esa ventana. Nunca se debe confundir "ese día no hay servicio" con "ese día está fuera de
   mis datos".
3. **Se toma prestada de escenario B la honestidad en la UI**: el tiempo real manda para
   "cuándo llega el próximo", y los horarios teóricos van siempre etiquetados como tales.

Si en una revisión posterior al 2026-09-07 el feed no se hubiera regenerado, la decisión
decaería automáticamente al **escenario B** (usar la topología, que seguiría siendo válida, y
apoyarse en el tiempo real para los horarios efectivos). El punto 2 de arriba hace que ese
cambio no requiera rediseñar nada.

---

## Hallazgo crítico: `stop_id` no es `stop_code`

Las paradas tienen **dos identificadores y no son intercambiables**:

| | Ejemplo | Para qué |
|---|---|---|
| GTFS `stop_id` | `3493` | Clave interna del GTFS; enlaza con `stop_times` |
| GTFS `stop_code` | `P006930` | Código público de la parada |

**La API de tiempo real usa la parte numérica de `stop_code`** (`P006930` → `6930`), **no el
`stop_id`**. Consultar con el `stop_id` devuelve **HTTP 200 con listas vacías** — un fallo
completamente silencioso.

La correspondencia se verificó sobre las 1.149 paradas: **1.149 coincidencias, 0 discrepancias**.

Por eso el código usa tipos Swift distintos para cada identificador, de forma que el compilador
impida confundirlos.

---

## Estado

| Fase | Estado |
|---|---|
| **Fase 0** — Verificación y cimientos | **Completa**, salvo los horarios de ferry (ver abajo) |
| **Fase 1** — Paradas y tiempo real | **Completa** |
| Fase 2 — Ferry de la ría | No iniciada |
| **Fase 3** — Planificador de rutas | **Completa** (solo bus; el ferry entra cuando exista la Fase 2) |
| Fase 4 — Pulido y comodidades | **Parcial**: lugares y trayectos guardados (CRUD completo), refresco del GTFS en segundo plano, orden de pestañas y estrella de favorito unificada. Quedan fuera, por decisión: widget de pantalla de inicio, atajos de Siri, accesibilidad exhaustiva |
| **Fase 5** — El mapa como planificador | **Completa** (a falta de la comprobación en dispositivo del propietario) |

### Fase 5 — el mapa es el planificador

El mapa dejó de ser un visor de paradas. Desde él se puede seleccionar **cualquier sitio** —una
parada, un punto de interés de Apple Maps, un punto cualquiera manteniéndolo pulsado, o un
resultado de búsqueda—, pedir "Cómo llegar" y ver hasta cuatro alternativas con sus horas, sus
trazados reales y el tiempo real del primer embarque, sin salir de la pantalla. Y las paradas
pasaron a ser una capa **apagada por defecto**: el mapa arranca limpio.

La pestaña "Planificar" sigue viva a propósito hasta completar la lista de paridad de once
puntos que `ESTADO.md` deja escrita; hoy falta uno (guardar el trayecto desde la hoja de ruta).

**Punto abierto de la Fase 0:** los horarios de ferry (punto 5) **no se pudieron recopilar**.
Las tres navieras publican sus horarios en imágenes y tablas generadas por JavaScript, no
extraíbles de forma fiable; una de ellas (Piratas de Nabia) sirve una imagen cuyo nombre indica
que es de 2024. No se ha inventado ningún horario. El detalle exacto de cada URL probada y su
respuesta está en [`DATA-SOURCES.md` §6](DATA-SOURCES.md). Habrá que transcribirlos a mano en la
Fase 2.

---

## Fuentes y atribución

- **Concello de Vigo** — GTFS de Vitrasa y datasets de transporte, bajo
  [Open Data Commons Attribution License (ODC-BY)](https://opendatacommons.org/licenses/by/).
- **[`David-Lor/VigoBusAPI`](https://github.com/David-Lor/VigoBusAPI)** (Apache-2.0) —
  documentación por ingeniería inversa de los endpoints de tiempo real.
- **[`arielcostas/infobus-bot`](https://github.com/arielcostas/infobus-bot)** —
  segunda referencia de endpoints y confirmación de la codificación ISO-8859-1.

Ninguno de esos proyectos aporta código a esta app; sirvieron para saber **a qué URL llamar y
qué esperar de vuelta**. Todo lo documentado aquí se volvió a verificar en vivo contra las
fuentes reales.
