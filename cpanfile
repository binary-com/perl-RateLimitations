requires 'perl',                    '5.0010000';
requires 'Cache::RedisDB',          '0.07';
requires 'Config::Onion',           '1.004';
requires 'File::ShareDir',          '1.102';
requires 'Time::Duration::Concise', '1.3';

on test => sub {
    requires 'Test::Most',          '0.34';
    requires 'Test::FailWarnings',  '0.008';
    recommends 'Test::RedisServer', '0.14';
};
