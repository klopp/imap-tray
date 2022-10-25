# IMAP-tray
Perl/Gtk IMAP уведомлятор.

Висит в трее и проверяет почту в указанных почтовых ящиках. При появлении новых писем меняет иконку и в тултипе показывает подробности. При клике по иконке запускает указанную почтовую программу (или делает то, что указано в конфиге).

Конфиг ищет в стандартных для *nix местах (см. [Config::Find](https://metacpan.org/pod/Config::Find)) или читает из первого аргумента командной строки:

```bash
    ./imap-tray.pl /home/user/imap-tray.conf
```

Формат конфига - перловый хэш:

```perl
{
    Debug    => 1,
    OnClick  => '/usr/bin/evolution',
    Interval => 120,
    #OnClick => sub
    #{
    #  print "Click\n";  
    #},
    Icons => {
        New       => 'new.png',
        Quit      => 'quit.png',
        Imap      => 'imap.png',
        Error     => 'error.png',
        NoNew     => 'nonew.png',
        ReConnect => 'reconnect.png',
    },
    IMAP =>
    {
        Yandex => 
        {
            Icon      => 'yandex.com.png',
            Active    => 1,
            Host      => 'imap.yandex.com:993',
            Login     => 'USER@yandex.ru',
            Password  => 'PASSWORD',
            ReconnectAfter  => 128,
            Detailed => 1, 
            Opt =>
            {
                use_ssl     => 1,
            },
            Mailboxes =>
            [
                'INBOX', 'Работа',
            ],
        },
        'Mail.RU' => 
        {
        # ...
        },
        Goolge => 
        {
        # ...
        },
    },
}
```

Имена параметров нечувствительны к регистру.

### Debug => ?

Если не undef/0, то выводит в STDOUT отладочные сообщения.

### OnClick => действие

Что делать по клике на иконку. Если это код, то он исполняется. Если нет - вызывается `system( действие )`.

### Interval => минуты

Интервал меджу проверками почтовых ящиков по умолчанию.

### Icons => { список }

Переопределение стандартных иконок. Файлы с иконками должны находиться в каталоге `i/` программы. Использовать на свой страх и риск, не рекомендуется.

### IMAP => список

Список почтовых серверов в формате

```perl
    Имя => { параметры }
```

#### Interval => минуты

Интервал меджу проверками почтовых ящиков. Если не задан используется *Interval* из основного раздела настроек.

#### Icon => file

Имя файла с иконкой почтового сервиса. Файл должен находиться в каталоге `i/m/` программы. Если не задано, то используется одна из предопределённых иконок. Если же таковой не найдётся - иконка по умолчанию (`i/imap.png`).

#### Active => ?

Если undef/0, то хост исключается из проверки. После запуска программы состояние меняется кликом по соответствующему пункту всплывающего меню.

#### Host, Login, Password, Mailboxes

Очевидно.

#### ReconnectAfter => попытки

После *попытки* проверок почты соединение с хостом закрывается и открывается снова.

#### Detailed => ?

Если не undef/0, то во всплывающем тултипе выводится количество новых писем для каждого ящика из *Mailboxes* отдельно. Иначе выводится общее количество новых писем.

#### Opt => { параметры }

Дополнительные параметры для соединения с хостом. Полный список можно посмотреть в списке параметров конструктора [Net::IMAP::Simple](https://metacpan.org/pod/Net::IMAP::Simple#new). На практике обычно достаточно 

```perl
    use_ssl => 1
```
