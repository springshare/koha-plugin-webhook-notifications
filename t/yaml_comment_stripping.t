#!/usr/bin/perl

use Modern::Perl;
use Test::More;
use YAML::XS qw(Load);

my $lib = '/var/lib/koha/kohadev/plugins';
unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/misc/translator/' );
unshift( @INC, '/kohadevbox/koha/t/lib/' );

use_ok('Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications')
    or BAIL_OUT('Cannot load plugin module');

my $strip = \&Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications::_strip_pound_comments_and_continuations;

subtest 'whole-line # comment is dropped' => sub {
    my $in = <<'YAML';
webhook: yes
# a comment
patron: 42
YAML
    my $out = $strip->($in);
    unlike $out, qr/a comment/, 'comment removed';
    my ($doc) = Load($out);
    is $doc->{patron}, 42, 'patron preserved';
};

subtest 'wrapped multi-line comment continuation is dropped' => sub {
    my $in = <<'YAML';
webhook: yes
holds:
#Title Small country houses: their repair and enlargement; forty examples
chosen from five centuries Weaver, Lawrence
1209903,
1209902,
YAML
    my $out = $strip->($in);
    unlike $out, qr/Lawrence/, 'continuation line removed';
    unlike $out, qr/Small country/, 'comment line removed';
    like   $out, qr/^1209903,$/m, 'id 1209903 preserved';
    like   $out, qr/^1209902,$/m, 'id 1209902 preserved';
};

subtest 'inline # comment on id line drops comment and continuation' => sub {
    my $in = <<'YAML';
webhook: yes
holds:
1209903, #Title Fast like a girl: a woman's guide to using the healing power of
burn fat, boost energy, and balance hormones Pelz, Mindy
1209902,
#Title The naked gun DVD gift
YAML
    my $out = $strip->($in);
    like   $out, qr/^1209903,\s*$/m, 'id 1209903 preserved without inline comment';
    unlike $out, qr/Pelz/,           'wrapped continuation dropped';
    unlike $out, qr/naked gun/,      'trailing whole-line comment dropped';
    like   $out, qr/^1209902,$/m,    'id 1209902 preserved';
};

subtest 'full noxious example parses end-to-end' => sub {
    my $in = <<'YAML';
webhook: yes
patron: 99
holds:
#Title Small country houses: their repair and enlargement; forty examples
chosen from five centuries Weaver, Lawrence
1209903, #Title Fast like a girl: a woman's guide to using the healing power of fasting to
burn fat, boost energy, and balance hormones Pelz, Mindy
1209902,
#Title The naked gun DVD gift
YAML

    my $stripped   = $strip->($in);
    my $normalize  = \&Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications::_normalize_yaml_flat_id_list_blocks;
    my $normalized = $normalize->($stripped);

    my $doc;
    eval { ($doc) = Load($normalized); };
    ok !$@, "YAML loads without error" or diag "load error: $@\nnormalized:\n$normalized";
    is $doc->{webhook}, 'yes', 'webhook key kept';
    is $doc->{patron},  99,    'patron kept';
    is $doc->{holds},   '1209903,1209902', 'holds collapsed to comma list';
};

subtest 'no-op when content has no # comments' => sub {
    my $in = <<'YAML';
webhook: yes
patron: 1
holds: 2,3
YAML
    is $strip->($in), $in, 'identical output when nothing to strip';
};

done_testing();
