# Chimera Linux Automated Installer

Автоматичний скрипт для встановлення та початкового налаштування **[Chimera Linux](https://chimera-linux.org/)** з LiveUSB («з коробки»).

## Особливості

- **Інтерактивний вибір накопичувача**: автоматичний пошук та аналіз доступних блочних пристроїв (`/dev/nvme*`, `/dev/sd*`, `/dev/vd*`) з відображенням розміру та моделі.
- **Файлова система Btrfs**:
  - Розмітка GPT (`sfdisk`) з 1 GiB ESP розділом (`FAT32`) та Btrfs на решту диска.
  - Оптимальна структура субтомів:
    - `@` — корінь `/`
    - `@home` — домашні каталоги `/home`
    - `@snapshots` — знімки системи `/.snapshots`
    - `@var_log` — системні журнали `/var/log`
  - Увімкнене прозоре стиснення `compress=zstd` та опція `noatime`.
  - Генерація чинного `/etc/fstab` з UUID.
- **Ядро та драйвери**:
  - Офіційне стабільне ядро `linux-stable`.
  - Повний набір мікрокоду та прошивок `base-full-firmware` для коректної роботи Wi-Fi, Ethernet, Intel/AMD/Nvidia GPU та аудіо на будь-якому "залізі".
- **Завантажувач Limine**:
  - Встановлення Limine для UEFI (`BOOTX64.EFI` / `BOOTAA64.EFI`) та BIOS (`limine bios-install`).
  - Реєстрація запису завантаження через `efibootmgr`.
  - Вбудований хук `/etc/kernel.d/99-limine.sh` для автоматичного оновлення `limine.conf` при будь-яких майбутніх апдейтах ядра.
- **Стиснення оперативної пам'яті (ZRAM)**:
  - Автоматичне налаштування swap на ZRAM з алгоритмом `zstd` (за замовчуванням 50% від обсягу RAM або довільний розмір).
  - Інтегрований нативний сервіс `dinit` (`zram-swap`), що стартує перед монтуванням swap.
- **Графічне оточення на вибір**:
  - **GNOME**: повний метапакет `gnome` + `gdm` + `gdm-dinit`.
  - **KDE Plasma**: `plasma-desktop` + `plasma-workspace` + `plasma-nm` + `sddm` + `sddm-dinit` + `konsole` + `dolphin`.
  - Звукова підсистема `pipewire` + `wireplumber`.
  - Мережевий менеджер `networkmanager` з автоматичним автозапуском.
- **Безпека та права**:
  - Створення користувача з доступом до `doas` (група `wheel`).
  - Підтримка паролів SHA-512 для користувача та `root`.

---

## Використання

1. Завантажтесь у **Chimera Linux LiveUSB**.
2. Відкрийте термінал або підключіться по SSH.
3. Завантажте та запустіть інсталятор:

```sh
# Завантаження скрипта
curl -O https://raw.githubusercontent.com/anon/chimera-installer/main/chimera-install-auto.sh

# Надання прав на виконання
chmod +x chimera-install-auto.sh

# Запуск з правами root
doas ./chimera-install-auto.sh
```

4. Дотримуйтесь підказок інсталятора (оберіть диск, оточення, ім'я користувача та пароль).
5. Після завершення перезавантажте систему:

```sh
doas reboot
```
