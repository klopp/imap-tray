# IMAP-Tray
Perl/Gtk IMAP уведомлятор.

Висит в трее и проверяет почту в указанных почтовых ящиках. При появлении новых писем меняет иконку и в тултипе показывает подробности. При клике по иконке запускает указанную почтовую программу (или делает то, что указано в конфиге).

Конфиг ищет в стандартных для *nix местах (см. [Config::Find](https://metacpan.org/pod/Config::Find)) или читает из первого аргумента командной строки:

```bash
    ./imap-tray.pl /home/user/imap-tray.conf
```

Формат конфига - перловый хэш:

```perl
{
    Debug    => 'warn',
    OnClick  => '/usr/bin/evolution',
    Interval => 2,
    #OnClick => sub
    #{
    #  print "Click\n";  
    #},

    IMAP =>
    {
        Yandex => 
        {
            # Icon      => 'online',
            Icon      => 'yandex.com.png',
            Active    => 1,
            Host      => 'imap.yandex.com:993',
            User      => 'USER@yandex.ru',
            Password  => 'PASSWORD',
            ReconnectAfter  => 128,
            Detailed => 1, 
            Opt =>
            {
                ssl     => 1,
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

Все фатальные ошибки пишутся в *syslog* и выбрасываются в *STDERR*.

## Debug => куда

Возможные значения:

* *warn* - использовать warn для вывода
* *carp* - использовать [Carp::carp](https://metacpan.org/pod/Carp) для вывода
* *file:имя_файла* - писать в *имя_файла*
* что-то другое - писать в STDOUT

P.S. Не влияет на отладочные сообщения внутри почтовых сессий, для этого нужно использовать ключ [debug](https://metacpan.org/pod/Mail::IMAPClient#Debug) в настройках IMAP (см. ниже).

## OnClick => действие

Что делать по клике на иконку. Если это код, то он исполняется. Если нет - вызывается `system( действие )`.

## Interval => минуты

Интервал меджу проверками почтовых ящиков по умолчанию.

## IMAP => список

Список почтовых серверов в формате

```perl
    Имя => { параметры }
```

### Interval => минуты

Интервал меджу проверками почтовых ящиков. Если не задан используется *Interval* из основного раздела настроек.

### Icon => location

Имя файла с иконкой почтового сервиса. Файл должен находиться в каталоге `i/m/` программы. Если не задано, то используется одна из предопределённых иконок. Если же таковой не найдётся - иконка по умолчанию (`i/imap.png`).
Если задать значение *"online"*, то будет произведена попытка получить иконку по данным хоста, не получится - по данным TLD хоста.

### Active => ?

Если undef/0, то хост исключается из проверки. После запуска программы состояние меняется кликом по соответствующему пункту всплывающего меню.

### Host, User, Password, Mailboxes

Очевидно.

### ReconnectAfter => попытки

После *попытки* проверок почты соединение с хостом закрывается и открывается снова.

### Detailed => ?

Если не undef/0, то во всплывающем тултипе выводится количество новых писем для каждого ящика из *Mailboxes* отдельно. Иначе выводится общее количество новых писем.

### Opt => { параметры }

Дополнительные параметры для соединения с хостом. Полный список можно посмотреть в списке параметров [Mail::IMAPClient](https://metacpan.org/pod/Mail::IMAPClient#Parameters). На практике обычно достаточно 

```perl
    ssl => 1
```

# Всякое разное

При использовании [birdtray](https://github.com/gyunaev/birdtray) поднимать Thunderbird имеет смысл так:

```perl
    OnClick => 'birdtray -s',
```
