# Deye Local

App nativa de iOS (SwiftUI) para monitorizar y controlar **microinversores Deye SUN-M G4 (4 MPPT)** de forma **100 % local**, hablando directamente con el logger WiFi por el protocolo **Solarman V5** (el mismo que usa `pysolarmanv5`), sin pasar por la nube de Solarman.

## Funciones

- Varios micros (IP + nº de serie del logger), con prueba de conexión
- Potencia AC, energía del día y total, potencia DC
- Por panel (PV1–PV4): tensión, corriente, potencia y energía del día y total
- Red: tensión, corriente, frecuencia y temperatura del equipo
- Estado (produciendo / en espera / alarma / fallo) y lista de fallos y alarmas activos
- **Encendido/apagado remoto** (registro 43)
- **Límite de potencia activa** 0–100 % (registro 40)
- Se actualiza solo cada 10 s, y también deslizando hacia abajo para recargar
- **Modo tablet** para iPad: panel a pantalla completa con la potencia total, la curva del día y una tarjeta por micro con sus 4 paneles

## Modo tablet (iPad)

En la lista de micros, pulsa el botón de cuadrícula (arriba a la derecha) y marca los micros que quieres ver; salen en el orden en que los marques. Después pulsa **Abrir**.

- Muestra la producción total (anillo con la potencia respecto a la nominal), la energía de hoy, el pico del día y el total acumulado.
- Dibuja la curva de potencia del día, con un punto por minuto mientras el modo tablet está abierto. Se guarda aunque cierres la app y se reinicia cada día.
- Cada micro tiene su tarjeta con potencia, barras por panel (PV1–PV4), energía de hoy, temperatura, tensión de red y avisos.
- Solo muestra datos: no se puede encender, apagar ni limitar desde aquí.
- La pantalla no se apaga mientras está abierto. Con la opción **Abrir en modo tablet al iniciar**, el iPad arranca directamente en el panel.
- Para salir, pulsa la X de arriba a la derecha.

## Estructura

```
DeyeLocal/
  Protocol/   ModbusRTU.swift, SolarmanV5.swift (tramas), SolarmanClient.swift (TCP)
  Model/      mapa de registros G4, servicio, almacenamiento, view model
  Views/      lista, detalle, alta/edición, modo tablet
DeyeLocalTests/   tests con vectores generados con pysolarmanv5
tools/mock_logger.py   simulador de logger + micro para pruebas
project.yml       proyecto XcodeGen (el .xcodeproj se genera solo)
.github/workflows/build.yml     compila, ejecuta los tests y genera un .ipa sin firmar
.github/workflows/release.yml   genera un .ipa firmado (y opcionalmente lo sube a TestFlight)
```

## Compilar desde GitHub (sin Mac)

1. Crea un repositorio en GitHub. Hazlo **público** si quieres minutos de macOS gratis ilimitados; en un repo privado, los 2.000 min/mes del plan Free equivalen a unos 200 min de macOS.
2. Sube el contenido de esta carpeta:
   ```bash
   git init && git add . && git commit -m "Deye Local"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/deye-local.git
   git push -u origin main
   ```
3. Ve a la pestaña **Actions → Build**. Se lanza solo con cada push. Tarda unos 5–8 minutos.
4. Al terminar, descarga el artefacto **DeyeLocal-unsigned-ipa**.

### Instalar en el iPhone

- **Sin cuenta de desarrollador:** usa [Sideloadly](https://sideloadly.io) (Windows o Mac). Conecta el iPhone por cable, arrastra el `.ipa` e inicia sesión con tu Apple ID normal. La app caduca a los 7 días y hay que volver a instalarla (o usa AltStore, que la renueva sola). En el iPhone tienes que activar **Ajustes → Privacidad y seguridad → Modo desarrollador**.
- **Con Apple Developer (99 $/año):** usa el workflow **Release** (ver abajo). Así puedes instalar en iPhones registrados (Ad Hoc) o distribuir por TestFlight.

### Release firmada

Crea el certificado **sin Mac**, con OpenSSL:

```bash
openssl genrsa -out ios.key 2048
openssl req -new -key ios.key -out ios.csr -subj "/emailAddress=tu@email.com/CN=Tu Nombre/C=ES"
# developer.apple.com > Certificates > + > Apple Distribution > sube ios.csr > descarga distribution.cer
openssl x509 -in distribution.cer -inform DER -out ios.pem
openssl pkcs12 -export -legacy -inkey ios.key -in ios.pem -out ios.p12
```

En developer.apple.com:

1. Crea un **App ID** `com.thermoaqua.deyelocal` (o el que quieras; el workflow lo toma del perfil).
2. Crea un **Provisioning Profile** de tipo *Ad Hoc* con los UDID de tus iPhones, o de tipo *App Store*.

En GitHub, ve a **Settings → Secrets and variables → Actions** y añade estos secrets:

| Secret | Valor |
|---|---|
| `P12_BASE64` | `base64 -w0 ios.p12` |
| `P12_PASSWORD` | contraseña del .p12 |
| `PROFILE_BASE64` | `base64 -w0 perfil.mobileprovision` |
| `KEYCHAIN_PASSWORD` | cualquiera |

(En Windows PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("ios.p12"))`)

Después ve a **Actions → Release → Run workflow** y elige `release-testing` (Ad Hoc) o `app-store-connect` (TestFlight).

## Probar sin el micro: simulador de logger

```bash
python3 tools/mock_logger.py --serial 2712345678
```

En la app, añade un micro con la IP de tu PC, puerto 8899 y nº de serie 2712345678. El simulador responde como un SUN-M G4 y acepta las órdenes de encendido/apagado y de límite de potencia. Comprobado también con `pysolarmanv5`.

## Notas importantes

- **Nº de serie:** es el del **logger** (10 dígitos), no el del inversor.
- **Puerto 8899:** algunos firmwares de logger de Deye de 2024 cerraron el acceso local. Compruébalo desde Windows con `Test-NetConnection IP -Port 8899`.
- **De noche** el micro está apagado: el logger responde, pero el inversor no. La app lo indica con un mensaje.
- **Registro 40 (límite):** según el firmware, el valor va en % (0–120) o en décimas (0–1200). En modo *Automático* la app lo deduce del valor actual (si es mayor que 120, son décimas). Si al aplicar un límite ves un valor raro, fija la escala a mano en la configuración del micro. El valor bruto aparece en *Información*.
- **Escrituras:** se usa la función Modbus **0x10** (la que aceptan los Deye).
- **Primera conexión:** iOS pide permiso de **Red local**. Hay que aceptarlo; si se deniega, actívalo en Ajustes → Deye Local.
- El mapa de registros sale de `deye_micro.yaml` de [ha-solarman](https://github.com/davidrapan/ha-solarman).

## Compilar en un Mac (si algún día tienes uno)

```bash
brew install xcodegen
xcodegen generate
open DeyeLocal.xcodeproj
```
