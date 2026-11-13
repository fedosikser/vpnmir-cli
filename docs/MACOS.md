# macOS

## Требования

- macOS 12 или новее.
- Установленное приложение VPN MIR. Его нужно открыть хотя бы один раз, войти и разрешить системное VPN-расширение.
- Для сборки на Intel Mac нужны Xcode Command Line Tools.

## Подключение

```bash
vpnmir l
vpnmir c BY
vpnmir s
```

Повторное подключение к последнему серверу:

```bash
vpnmir c
```

Отключение:

```bash
vpnmir d
```

## Autorenew

Режим включён по умолчанию. После подключения запускается фоновый watchdog, который обновляет соединение через 59 минут.

```bash
vpnmir r status
vpnmir r on
vpnmir r off
vpn r 40
```

`vpn r 40` включает режим и задаёт интервал 40 минут. Выбранный интервал
сохраняется после `off` и повторного `on`.

Лог watchdog: `~/Library/Application Support/vpnmir-cli/autorenew.log`.
