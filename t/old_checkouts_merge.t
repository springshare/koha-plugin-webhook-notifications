#!/usr/bin/perl

use Modern::Perl;
use Test::More;

my $lib = '/var/lib/koha/kohadev/plugins';
unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/misc/translator/' );
unshift( @INC, '/kohadevbox/koha/t/lib/' );

use_ok('Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications')
    or BAIL_OUT('Cannot load plugin module');

my $class = 'Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications';

# Koha renders a CHECKIN template once per returned item and concatenates the
# fragments, so a patron returning several items produces several segments.
sub checkin_body {
    my (@issue_ids) = @_;
    return join( "\n", map { <<"SEGMENT" } @issue_ids );
---
webhook: yes
library: MAIN
old_checkouts:
----
$_,
----
---
SEGMENT
}

subtest 'multi-item checkin keeps every old checkout id' => sub {
    my ( $docs, $orphans )
        = $class->load_yaml_documents_from_message_content( checkin_body( 101, 102, 103 ) );

    my $merged = $class->merge_webhook_yaml_documents( $docs, $orphans );

    ok $merged, 'merged mapping produced';
    is $merged->{old_checkouts}, '101,102,103',
        'all three ids survive the merge under the plural key';
    is $merged->{library}, 'MAIN', 'library carried through';
};

subtest 'single-item checkin still works' => sub {
    my ( $docs, $orphans )
        = $class->load_yaml_documents_from_message_content( checkin_body(101) );

    my $merged = $class->merge_webhook_yaml_documents( $docs, $orphans );

    ok $merged, 'merged mapping produced';
    is $merged->{old_checkouts}, '101', 'the single id is present';
};

subtest 'legacy single-event mapping template still merges' => sub {
    my $body = <<'YAML';
---
webhook: yes
old_checkout: 201
patron: 55
library: MAIN
---
----
---
webhook: yes
old_checkout: 202
patron: 55
library: MAIN
---
YAML

    my ( $docs, $orphans ) = $class->load_yaml_documents_from_message_content($body);
    my $merged = $class->merge_webhook_yaml_documents( $docs, $orphans );

    ok $merged, 'merged mapping produced';
    is $merged->{old_checkouts}, '201,202',
        'singular old_checkout ids are merged under the plural key';
    is $merged->{patron}, 55, 'patron carried through';
};

subtest 'old checkout ids do not leak into checkouts or holds' => sub {
    my ( $docs, $orphans )
        = $class->load_yaml_documents_from_message_content( checkin_body( 101, 102 ) );

    my $merged = $class->merge_webhook_yaml_documents( $docs, $orphans );

    ok !exists $merged->{checkouts}, 'no checkouts key';
    ok !exists $merged->{holds},     'no holds key';
};

subtest 'checkout digest is unaffected' => sub {
    my $body = join( "\n", map { <<"SEGMENT" } ( 301, 302 ) );
---
webhook: yes
library: MAIN
checkouts:
----
$_,
----
---
SEGMENT

    my ( $docs, $orphans ) = $class->load_yaml_documents_from_message_content($body);
    my $merged = $class->merge_webhook_yaml_documents( $docs, $orphans );

    is $merged->{checkouts}, '301,302', 'checkout ids still attach to checkouts';
    ok !exists $merged->{old_checkouts}, 'no old_checkouts key';
};

done_testing();
