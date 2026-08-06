# Directrices para construir apps de macOS

Notas destiladas de este código. Cada regla existe porque su ausencia fue un
bug real que llegó a producción; la referencia al final de cada punto lleva
al lugar donde está resuelta.

## 1. Concurrencia

- **Todo trabajo bloqueante va por GCD, esperado desde Swift Concurrency —
  nunca directo en un `Task`.** El pool cooperativo tiene un carril por
  núcleo; un escaneo de disco lanzado ahí ahoga al resto de la app ("cambié
  de pestaña y se congeló"). Y mover el trabajo a GCD no basta: hay que
  acotar el paralelismo con un semáforo *async* (`Gate`, ancho ~2×núcleos),
  porque GCD topa cerca de 64 hilos y un `DispatchSemaphore` aparcaría
  justo los hilos que se intentan conservar. → `DiskScanKit/Blocking.swift`
- **`Task.isCancelled` es siempre falso dentro de un closure de GCD.** La
  cancelación debe cruzar el salto como objeto explícito (`CancelFlag`),
  consultado cada ~2048 entradas del bucle. Sin esto, reiniciar un escaneo
  tres veces deja tres recorridos completos corriendo hasta el final.
  → `DiskScanKit/CancelFlag.swift`
- **No sostener un lock a través de syscalls**: copiar el estado bajo el
  lock, soltar, y hacer las llamadas fuera. → `SystemKit/ProcessMemory.swift`
- **En un task repetitivo con `[weak self]`, `await self?.metodo()` con self
  nil es un no-op, no una salida.** Un heartbeat así quedó haciendo ping a
  la nada cada 5 s por el resto de la vida de la app. Ligar self con guard
  y `return`. → `CastKit/GoogleCast.swift`
- **Elegir primitivas por target de despliegue**: `Mutex` (Synchronization)
  es macOS 15+; un envoltorio sobre `NSLock` era lo único que mantenía la
  app compatible con macOS 14. → `DiskScanKit/Locked.swift`

## 2. Procesos externos

- **Un timeout de subproceso debe *abandonar* al hijo, no esperarlo.** Un
  task group con un "corredor" que duerme reporta el timeout pero sigue
  esperando: un hijo que atrapa SIGTERM, o que sale dejando un nieto con el
  pipe abierto, no vuelve jamás. Deadline propio + escalada SIGTERM→SIGKILL
  a los 1.5 s. → `SystemKit/ShellRunner.swift`
- **Drenar los pipes del hijo con `readabilityHandler` mientras corre,
  nunca `readDataToEndOfFile` ni después de `waitUntilExit`.** Un pipe
  retiene ~64 KB; lleno, el hijo se bloquea escribiendo y tú esperando —
  y cada lectura bloqueante aparca un hilo de GCD del pool global.
  → `SystemKit/ShellRunner.swift`, `StreamHostKit/HostIdentity.swift`
- **Capar la salida acumulada del hijo** (4 MB por stream, conservando el
  inicio): un proceso verborrágico con timeout de 300 s llena la memoria.
- **Sanear el entorno de CLIs de terceros**: `brew` se auto-actualiza y
  consulta su API en comandos incidentales — en una red lenta eso parece
  una pantalla congelada. Variables de entorno que lo desactivan + plazo
  corto siempre. → `SystemKit/Maintenance.swift`
- **La UI nunca espera a un proceso externo sin plazo**: renderizar primero
  con datos locales (parsear el plist es puro I/O que no puede colgarse) y
  sondear después, en paralelo, con timeouts cortos — el tiempo total es el
  del probe más lento, nunca la suma. → `SystemKit/LaunchAgents.swift`
- **Firmar procesos con cuidado**: actuar sobre el *árbol* (congelar solo
  al padre deja a los hijos de Electron quemando CPU); re-verificar
  (pid, hora de inicio) antes de cada señal — un pid reciclado no se toca;
  y el guard contra señalarte a ti mismo o a un ancestro va en el syscall,
  no en las buenas intenciones del caller (un SIGSTOP a tu propio árbol no
  tiene vuelta: no queda nadie para el SIGCONT).
  → `SystemKit/ProcessPauser.swift`
- **`NSWorkspace.runningApplications` solo conoce apps con bundle.** "Cerrar
  node" no hacía nada y reportaba éxito. Apps → `terminate()` (pueden
  preguntar por cambios sin guardar); procesos planos → SIGTERM, no SIGKILL
  (un servidor cierra sockets, un build borra temporales). Y nombrar
  intérpretes por su script: "node, 1.5 GB" eran tres servidores que el
  usuario habría matado sin saber qué eran. → `SystemKit/AppTerminator.swift`

## 3. SwiftUI y Observation (rendimiento)

- **Nada caro en `body` ni en propiedades computadas que `body` lee.** Un
  computed que enumeraba procesos vía NSWorkspace corría cinco veces por
  render de una tarjeta. Derivar agregados en el modelo cuando cambian los
  datos, nunca al dibujar. → `AppState.swift`, `DeepCleanModel.swift`
- **Almacenar la respuesta a cualquier pregunta syscall/IPC y refrescarla
  solo cuando puede cambiar**: un `getifaddrs` por render, o una consulta
  XPC a `SMAppService` dentro del getter de un `Binding`, son el mismo bug
  con distinto disfraz. → `CastModel.swift`
- **`@Observable` publica en cada `set` aunque el valor sea idéntico**:
  proteger las escrituras con comparación de igualdad, o cada refresco
  re-renderiza pantallas enteras para nada.
- **Marcar cachés de render con `@ObservationIgnored`**: una caché leída y
  escrita durante `body` es un ciclo invalidar→render→invalidar.
  → `UninstallerModel.swift`
- **`Identifiable.id` derivado de datos estables — jamás `UUID()` en una
  colección computada**: ids frescos por lectura hacen que `ForEach`
  destruya y recree el subárbol entero en vez de actualizarlo.
- **Cachear layouts caros dentro de `GeometryReader` con una clave
  `Equatable` de exactamente sus entradas**: el body de un GeometryReader
  corre en cada cambio de hover. → `TreemapView.swift`
- **Partir bodies largos en subvistas privadas**: un body anidado gigante
  compila a un único tipo genérico que SwiftUI re-lay-outa completo ante
  cualquier cambio.
- **Todo flag de "ocupado" lleva un deadline que lo apaga**: un
  `ProgressView` indeterminado invalida su vista cada frame por diseño —
  uno olvidado en pantalla es un core al 100% y cientos de MB/s de churn
  haciendo nada. → `BusyDeadline.swift`

## 4. Apps de barra de menús (la app nunca muere)

- **Todo `onAppear` que arranca algo necesita su stop atado a
  *visibilidad*, no a "modo activo".** En una app que vive semanas,
  "mientras esté activo" significa "para siempre": browsers Bonjour,
  samplers a 1 Hz, polls de posición — todo con refcount de espectadores.
  → `CastModel.discoveryViewAppeared`, `GamingModel.statsViewerAppeared`
- **Los bucles de sondeo deben terminar solos**, no solo por acción del
  usuario: fin de pista, N respuestas perdidas, deadline.
- **Ocultar un `NSPanel` exige soltar su `contentView`, no solo
  `orderOut`**: una `NSHostingView` invisible mantiene vivos sus `.task`.
  El panel se conserva para el autosave del frame. → `DesktopWidget.swift`
- **Cerrar la ventana degrada la app a `.accessory`, no la cierra**; al
  reabrir se promueve a `.regular`. Y hay que subir la ventana desde el
  delegate con reintentos: SwiftUI crea la NSWindow con pereza y macOS
  puede restaurar un estado "sin ventanas". → `ChinchillaApp.swift`
- **Detectar el arranque como login item** (uptime < 180 s) y empezar en
  silencio en la barra, sin plantar una ventana en la cara del usuario.
- **Un watchdog de congelamientos no puede compartir carril con lo que
  vigila**: uno `@MainActor` no corre justo cuando el main thread está
  atascado — "es decoración". → `StallDetector.swift`
- **Persistir la intención antes de cambios invisibles y reversibles del
  sistema** (silenciar el audio, congelar apps): si la app crashea a mitad,
  el próximo arranque restaura. → `SystemKit/OutputMute.swift`

## 5. La toolbar (se ganó su propia sección)

- **El conjunto de ítems de la toolbar de la ventana no cambia jamás.**
  Ítems con id fijo cuyos *contenidos* cambian. Un if/else que intercambiaba
  vistas — o una pantalla que añade su propio `.toolbar { }` — hace que
  AppKit reconstruya la toolbar entera y entre en un live-lock de
  reconstrucción a 100% de un core, sin una línea propia en el stack.
- **Dentro de un ítem, `Image(systemName:)` pelado, no `Label` con
  estilo**: AppKit construye una representación de menú por ítem, y un
  label custom re-resuelve su imagen por CUICatalog (con fallback de
  localización) en cada pasada. → `MainWindow.swift` (las dos reglas están
  documentadas ahí; costaron dos congelamientos separados).

## 6. Permisos (TCC) y firma

- **Los permisos TCC se asocian al bundle y al proceso que lanza.** Probar
  siempre desde el bundle compilado (nunca `swift run`); los diagnósticos
  se lanzan con `open -a App --args ...` porque el binario desde la shell
  reporta los permisos de la Terminal, no los de la app.
- **Firmar cada build con identidad estable** (Developer ID → certificado
  autofirmado → ad-hoc, en ese orden): la identidad estable es lo que hace
  que Acceso Total al Disco sobreviva a los rebuilds. → `build-app.sh`
- **Detectar permisos intentando el acceso y leyendo `errno`, no
  preguntando**: FDA se prueba con `opendir` de una ruta protegida; que la
  ruta no exista se trata como accesible, no como denegado.
  → `SystemKit/Permissions.swift`
- **Grabación de pantalla**: macOS solo relee el permiso tras relanzar la
  app — la UI debe decirlo, o parece que el permiso "no funcionó".

## 7. Archivos, logs e IPC por archivos

- **Todo log append-only rota, y rota por bytes *y* por líneas.** Rotar
  solo por líneas dejó un archivo permanentemente sobre su tope de bytes,
  releyéndose completo en cada append sin encogerse nunca. El costo de usar
  la app no puede crecer con la antigüedad de la instalación.
  → `SystemKit/RollingLog.swift`
- **Un contador de por vida es un archivo aparte del log que rota**, y se
  actualiza en el mismo punto que escribe el log para que no discrepen.
  → `SystemKit/CleanTotals.swift`
- **JSONL defensivo**: una línea rota (app matada a mitad de append) se
  salta; no le cuesta al lector las otras 200.
- **IPC por archivos**: un archivo por proceso (Chrome lanza un host por
  perfil — `status-<pid>.json`); sondear con `stat` (size+mtime) antes de
  releer y decodificar; y saltarse escrituras que no cambian nada.
  → `SystemKit/NativeMessaging.swift`
- **Formatos en disco desacoplados de constantes del kernel** (niveles como
  strings, no los enteros de un header que no controlas).

## 8. Borrar con seguridad (si tu app borra archivos)

- **Un solo chokepoint de validación debajo de la UI** — CLI, limpieza
  programada y features futuras pasan por el mismo; un check en una vista
  "simplemente sería evitado". → `CleanCore/SafetyPolicy.swift`
- **Validar la ruta resuelta de symlinks y borrar *esa* ruta**, no la
  original: validar una y borrar la otra es una ventana TOCTOU.
- **La deny-list es más que carpetas del sistema**: iCloud Drive, llaveros,
  TCC, rutas con menos de 3 componentes, flags SIP/immutable, y nombres que
  viven *dentro* de cachés pero guardan estado de sesión/sync.
- **Vista previa por defecto; a la Papelera, no unlink**, salvo cachés
  clasificadas seguras. Contenedor ilegible = fallo, no éxito silencioso
  ("no acreditar bytes que no borramos"). Todo al log de auditoría.
- **Deduplicar resultados por ruta antes de mostrarlos**: dos reglas que
  encuentran la misma carpeta son bytes contados dos veces, un borrado
  doble, y dos filas con la misma identidad girando el view graph.
- **Jamás descender en placeholders de nube (`SF_DATALESS`)**: tocarlos
  puede *re-descargar* los datos del usuario durante un escaneo.
  → `DiskScanKit/FTSWalker.swift`

## 9. Red (Network.framework)

- **Cancelar un `NWListener` no cancela sus conexiones.** Registro de
  conexiones vivas, canceladas todas en `stop()`. Y si reemplazas el
  `stateUpdateHandler` de una conexión, el reemplazo hereda la contabilidad
  del original. → `CastKit/HTTPServer.swift`
- **Backpressure siempre**: para media en vivo, tope de bytes en vuelo y
  el cliente lento se cae (no hay buffer que salve un enlace más lento que
  el video); para archivos, esperar `contentProcessed` antes de leer más.
- **HTTP keep-alive implica seguir leyendo tras responder** y acarrear los
  bytes sobrantes al siguiente request, o todo cliente que reúse la
  conexión se cuelga en su segunda petición.
- **Bonjour**: cada tipo de servicio que browseas debe estar en
  `NSBonjourServices` — macOS rechaza en *silencio* los no declarados (el
  browser dice "ready" y no entrega nada); un test compara el código contra
  el Info.plist. `.waiting` = permiso de red local denegado: se muestra.
  Los browses son continuos: "Refrescar" jamás los reinicia (vacía la
  lista); reinicia solo lo one-shot. → `BonjourDeclarationTests.swift`
- **Elegir la IP local por la subred del destino, no asumiendo `en0`**:
  con VPN o Docker, `en0` no es la interfaz que el TV alcanza.
- **`AsyncStream`: `finish()` en *todo* camino terminal** — incluido el FIN
  remoto que llega con la conexión aún `.ready` y no dispara los estados de
  error. Sin finish, los consumidores esperan para siempre.

## 10. Media en tiempo real

- **Envolver toda API del sistema que puede colgarse en un deadline
  propio** (`SCShareableContent` ni retorna ni lanza cuando su daemon se
  atasca), y no emitir la consulta si esa fuente no la necesita.
- **Todo `start()` multi-paso canaliza cada throw por el mismo teardown que
  `stop()`**, y el teardown se activa por "¿existe algún recurso?", no por
  un flag que se setea en la última línea (200 intentos fallidos = 205 file
  descriptors abiertos, con límite de 256). → `CastMirrorSession.swift`
- **Retimear buffers de captura a origen cero**: ScreenCaptureKit estampa
  con host time — millones de segundos de uptime — y un player en vivo con
  eso no renderiza nada.
- **Relojes honestos para lip-sync**: los sender reports emparejan el
  timestamp RTP con el instante de *captura*, no con "ahora" (el sesgo por
  stream va directo a la sincronía); los timestamps de audio se derivan del
  reloj de captura con resincronización ante huecos, nunca de un contador
  ciego de muestras.
- **Encoder para espejo ≠ encoder para archivo**: low-latency rate control,
  sin reordenamiento de frames, techo duro además del promedio, GOP largo
  con keyframes bajo demanda (escritorio quieto: de ~1.7 Mbps a ~150 kbps).
  SPS/PPS inline antes de *cada* keyframe, o quien se une tarde no puede
  configurar su decoder. → `RealtimeH264Encoder.swift`
- **El stream es su propia sonda de ancho de banda**: no hay speed test
  contra un receptor que no coopera. La lógica de adaptación vive en un
  struct puro y sin reloj, testeable tick a tick — así se encontraron los
  bugs de verdad (el tráfico idle no es evidencia; una subida fallida
  duplica la calma exigida a la siguiente; la cola del RTT p95 baja el
  escalón antes de perder el primer paquete). → `AdaptiveQuality.swift`
- **No creer el estado *reportado* por el peer como confirmación de un
  cambio in-band**: el receptor Cast repite el valor del OFFER para
  siempre mientras honra el cambio real — el usuario sintiendo 350 ms de
  diferencia valía más que la telemetría.

## 11. Robustez ante bytes hostiles

- **Todo framer con prefijo de longitud lleva tope de tamaño, verificado
  antes de esperar los bytes**: un peer que anuncia 4 GB y gotea bytes
  crece el buffer hasta matar el proceso.
- **Parsear formatos de red con `Int(exactly:)` e
  `index(_:offsetBy:limitedBy:)`**: el `Int(_:)` normal *trapea*, y un trap
  sobre bytes controlados por el atacante es un kill switch remoto (la
  sesión Cast acepta cualquier certificado TLS por diseño — cualquiera en
  el puerto 8009 podía tumbar la app). La suite se llama "A hostile TV
  can't take the app down". → `GoogleCast.swift`, `CastStreamingTests.swift`

## 12. Empaquetado, distribución, auto-update

- **Se puede armar una .app real sin Xcode**: `swift build` por triple +
  `lipo`, y `Contents/` ensamblado a mano (Info.plist, PkgInfo, `.lproj`,
  el LaunchAgent embebido para `SMAppService`). → `scripts/build-app.sh`
- **El script de release hace preflight** (certificado, perfil de notaría —
  fallando temprano con el comando exacto para arreglarlo) **y verifica el
  DMG como lo haría el Mac de un usuario** (`spctl` tras el staple).
- **El self-update verifica firma *y* team ID del bundle descargado antes
  de tocar nada**; el swap del bundle va fuera del main thread (copiarlo en
  el main actor parecía un cuelgue); y la sesión de descarga lleva timeout
  propio — el de `URLSession.shared` es de siete días.
  → `UpdateModel.swift`
- **Actualizar pregunta primero**, con las novedades en palabras simples —
  el lector es un profesor, no un changelog. Los releases se escriben con
  el resumen llano arriba y el detalle técnico bajo un `---`.
- **CLI y modos headless se despachan en `@main` antes de que exista
  maquinaria de GUI** — el mismo binario sirve `scan --json` por SSH y como
  host de native messaging sin bootear una instancia gráfica.

## 13. Producto: honestidad como arquitectura

- Lo que la app *no* hace va explícito (no libera RAM, no infla cifras):
  cada optimización real, reversible y sin root.
- "No sé" ≠ "cero": un campo que este Mac no puede responder se omite del
  JSON, no se rellena con ceros; un daemon inalcanzable no es permiso para
  actuar.
- Preferir siempre la acción reversible que no pide root (`stopbackup`
  re-emitido vs `disable` persistente; que macOS elija qué snapshot borrar).
- Comandos privilegiados = strings literales fijos por `osascript`:
  superficie de inyección cero.

## 14. Tests y depuración de campo

- **La lógica de decisión se extrae pura y sin reloj** para poder testearla
  tick a tick; lo que depende de daemons de GUI (displays virtuales) se
  documenta como no-testeable y por qué.
- **Cada regresión lleva su historia en el doc comment del test**, y las
  suites se nombran por lo que protegen ("Deadlines are actually
  enforced"). Vectores dorados generados con herramientas independientes
  (openssl) y payloads capturados de dispositivos reales, con fecha.
- **Un test que parpadea bajo carga se endurece con la misma cortesía que
  su pre-check** (reintentos sobre snapshots del kernel), no se ignora.
- **Congelamientos en producción**: `sample <pid>` *antes* de matar el
  proceso, y `log show --predicate` — el aviso de AppKit "layout has
  continued for 300 iterations" diagnosticó en un minuto lo que la
  especulación no habría encontrado.
- **Cuando el sensor y el usuario discrepan por 300 ms, se le cree al
  usuario y se investiga al sensor.**
