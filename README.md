# MiMedia 5.0: primera aplicación iOS personal

Este directorio es independiente de Android y de la PWA. Reutiliza el aspecto, el logotipo y parte de la lógica de `ios-web`, pero incluye una aplicación SwiftUI con WKWebView local. Los archivos de música, las descargas y el reproductor son nativos. No abre una web alojada ni necesita publicar una página. Se ha elegido este puente pequeño en lugar de añadir Capacitor y complementos: utiliza únicamente frameworks de Apple y XcodeGen para generar el proyecto.

**Estado: fuentes preparadas; todavía NO hay IPA compilado, firmado ni instalado.** Windows no tiene Xcode. La primera ejecución remota puede descubrir errores de Swift o del empaquetado que habrá que corregir. No se ha verificado Safari, un simulador ni un iPhone real.

## Qué incluye el código

- Cuatro pestañas: Inicio, Buscar, Biblioteca y Playlists; identidad visual existente.
- Enlaces HTTPS individuales o múltiples y confirmación obligatoria de autorización. URLSession descarga archivos reales; no se ha sustituido la descarga por importación. No necesita CORS del navegador.
- Cola secuencial, progreso cuando el servidor comunica tamaño, cancelación, reintentos y duplicados por URL y SHA-256. Límite de 150 MB por audio. Solo se incorpora un archivo después de comprobar respuesta completa y audio reproducible con AVAudioPlayer.
- Música en Application Support/MiMedia/Music y catálogo JSON con escritura atómica. Favoritos, búsqueda, álbumes/artistas a partir de los datos editados, carátulas y playlists. No hay identificación automática de canciones ni migración desde Android o la PWA.
- AVAudioPlayer, sesión `.playback`, modo de fondo `audio` y comandos del Centro de control. La cola musical avanza en Swift, sin depender de JavaScript activo. Esto prepara reproducción offline y con pantalla bloqueada; ambas necesitan prueba real.
- Compartir un archivo para guardar una copia. Desinstalar puede borrar la biblioteca; no existe copia automática ni sincronización.
- Ayuda con un tono local claramente identificado como prueba, no como descarga.

En esta primera versión debes mantener MiMedia abierta durante las descargas. No se implementa todavía URLSession de fondo, reanudación parcial ni garantía de terminar una descarga con la pantalla bloqueada. Los formatos efectivos dependen de AVAudioPlayer en el dispositivo. Una página con un reproductor no equivale a un enlace directo de audio.

YouTube se identifica y muestra como fuente pendiente: no se extrae ni se descarga audio. No se incluye conversor, yt-dlp, proxy ni servidor. Marcar autorización no elimina restricciones técnicas o contractuales; la API oficial no habilita una descarga general de audio. Referencias: [políticas de desarrolladores de YouTube](https://developers.google.com/youtube/terms/developer-policies), [condiciones de YouTube](https://www.youtube.com/static?template=terms). No se promete compatibilidad futura.

## Obtener el primer IPA desde Windows

1. Esta copia contiene exclusivamente el proyecto iPhone, listo para el repositorio privado `rifirafe777/MiMedia-iPhone`. No incluye el proyecto Android.
2. El commit local se prepara para revision. No subir ni ejecutar Actions hasta recibir la aprobacion expresa del usuario. El remoto configurado debe ser exactamente `https://github.com/rifirafe777/MiMedia-iPhone.git`. Si el repositorio remoto ya tiene commits, primero habra que revisarlos e integrarlos sin sobrescribirlos.
3. Antes de ejecutar, revisa **Settings → Billing and licensing → Budgets and alerts** de tu cuenta. Para uso privado comprueba saldo incluido y un presupuesto con bloqueo al agotarse; no habilites gasto adicional. Si no tienes cuota, espera a su renovación o consulta otra opción. Los ejecutores estándar de repositorios públicos son gratuitos para cómputo, pero convertirlo en público expone tus fuentes. No lo hagas sin decidirlo expresamente. El almacenamiento tiene sus propias condiciones. [Facturación oficial de Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
4. En GitHub abre el repositorio → **Actions** → **Compilar MiMedia IPA sin firma** → **Run workflow**. Si GitHub pide habilitar Actions, hazlo únicamente para ese repositorio. Solo hay ejecución manual, con macOS estándar y un límite de 30 minutos.
5. Espera al resultado. Si aparece rojo, abre el paso fallido y conserva el registro; puede haber un artefacto `MiMedia-diagnostico`. **No significa que exista un IPA.** Será necesario corregir el error antes de seguir.
6. Si termina en verde, descarga el artefacto **MiMedia-IPA-sin-firma** al final de esa ejecución y descomprime el ZIP. El archivo esperado es **MiMedia-unsigned.ipa**, acompañado de registro, estado y SHA-256. El script exige aplicación arm64, ejecutable Mach-O, recursos, audio de prueba y estructura Payload antes de entregarlo. Esto verifica empaquetado, no funcionamiento en un iPhone.

No hacen falta certificados ni Apple ID en GitHub: el IPA se construye sin firma. El artefacto se conserva siete días. No se configura GitHub Pages, Cloudflare ni servidor de música. El portátil puede apagarse mientras trabaja el ejecutor remoto.

## Instalar personalmente mediante AltStore Classic

No basta con enviar un IPA y tocarlo como un APK: primero se necesita firma personal. Sigue la [guía oficial de AltStore para Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows):

1. Instala los componentes iTunes/iCloud indicados por esa guía y AltServer para Windows. La guía distingue las versiones de Apple y Microsoft Store.
2. Abre AltServer, conecta el iPhone por USB, desbloquéalo y acepta confiar en el ordenador. Activa sincronización Wi-Fi en iTunes.
3. Desde el icono de AltServer elige **Install AltStore → tu iPhone** e introduce personalmente tu cuenta Apple. No pongas esas credenciales en el repositorio ni en Actions.
4. En el iPhone confía en el perfil instalado en **Ajustes → General → VPN y gestión de dispositivos**. Activa **Modo de desarrollador** en **Privacidad y seguridad**, con el reinicio requerido.
5. Transfiere el IPA obtenido a **Archivos** del iPhone, por ejemplo mediante iCloud Drive. Con AltServer disponible, abre AltStore → **My Apps** → **+**, selecciona el IPA y espera a que lo firme e instale. Abre MiMedia desde su icono.

Con cuenta gratuita hay caducidad de siete días y límite de tres aplicaciones activas, contando AltStore. Renueva con **Refresh All** y AltServer accesible antes de caducar. El ordenador se necesita para instalar/renovar, no para escuchar los archivos ya guardados. No cambies de cuenta o identificador ni desinstales sin exportar música. [Límites y renovación](https://faq.altstore.io/altstore-classic/your-altstore).

## Primera comprobación en el iPhone

1. Abre Ayuda y añade el **tono de prueba local**. Reprodúcelo desde Biblioteca: este paso no usa Internet ni acredita descargas.
2. Es un tono corto: selecciona **Repetir: una**, baja el volumen y bloquea el iPhone. Comprueba que sigue sonando y prueba pausa desde la pantalla bloqueada. Después quita la repetición.
3. Pega un enlace HTTPS directo de un audio que controles o tengas permiso de descargar. Marca autorización y espera a que termine sin cerrar la app. Si falla, conserva el mensaje y el enlace no privado para diagnosticarlo.
4. Activa modo avión, comprueba también Wi-Fi desactivado, abre la canción guardada y bloquea la pantalla. Debe sonar sin servidor ni portátil. Cierra y vuelve a abrir MiMedia: verifica persistencia.
5. Prueba cancelación, reintento con autorización, duplicado, favoritos, edición, una playlist y compartir archivo. Un enlace YouTube debe mostrar fuente pendiente sin añadir una falsa canción descargada.

Hasta completar estas pruebas no debe darse por validada la experiencia nativa. Pendientes además: compilación Xcode inicial, firma personal, compatibilidad de tu versión de iOS, interrupciones/auriculares, almacenamiento lleno, descargas largas, accesibilidad y recuperación ante fallos reales.

## Desarrollo y comprobaciones locales

`Web` contiene los recursos locales preparados y es autosuficiente en macOS. `Frontend/native-app.js` conserva el codigo de interfaz para mantenimiento. No hay configuracion ni dependencia de Capacitor: este proyecto utiliza SwiftUI, WKWebView, Foundation, UIKit, AVFoundation, MediaPlayer y CryptoKit de Apple. XcodeGen es la herramienta externa instalada por el workflow; no se requiere npm ni node_modules para compilar. Con Node disponible, desde esta carpeta se puede ejecutar:

```powershell
node -e "import('./tests/check-source.mjs').then(async m=>console.log(await m.checkSources()))"
```

Son comprobaciones estáticas de JavaScript, puente y recursos; no prueban Swift ni audio. En un Mac con Xcode y [XcodeGen](https://github.com/yonaskolb/XcodeGen), `bash scripts/build-unsigned.sh` realiza la compilación real. Requisitos de este proyecto: iPhone con iOS 16 o posterior; el ejecutor remoto debe tener SDK compatible con el dispositivo.

MiMedia Android, APK, firma y base de datos no forman parte del paquete y no se modifican.
