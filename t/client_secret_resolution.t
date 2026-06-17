#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

use Modern::Perl;
use Test::More;

my $lib = '/var/lib/koha/kohadev/plugins';
unshift( @INC, $lib );
unshift( @INC, '/kohadevbox/koha/' );
unshift( @INC, '/kohadevbox/koha/misc/translator/' );
unshift( @INC, '/kohadevbox/koha/t/lib/' );

use_ok('Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications')
    or BAIL_OUT('Cannot load plugin module');

my $resolve =
    \&Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications::_resolve_client_secret;
my $mask =
    $Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications::MASKED_SECRET_PLACEHOLDER;

ok( defined $mask && length $mask, 'masked placeholder constant is defined' );

subtest 'masked placeholder submission keeps the stored secret' => sub {
    is $resolve->( $mask, 'real-secret' ), 'real-secret',
        'submitting the unchanged mask preserves the stored secret';
};

subtest 'empty or undef submission keeps the stored secret' => sub {
    is $resolve->( '',    'real-secret' ), 'real-secret', 'empty string keeps existing';
    is $resolve->( undef, 'real-secret' ), 'real-secret', 'undef keeps existing';
};

subtest 'a newly typed secret replaces the stored one' => sub {
    is $resolve->( 'brand-new-secret', 'real-secret' ), 'brand-new-secret',
        'a real new value is used';
    is $resolve->( 'brand-new-secret', undef ), 'brand-new-secret',
        'a real new value is used even with nothing stored';
};

subtest 'masked submission with nothing stored resolves to undef' => sub {
    is $resolve->( $mask, undef ), undef,
        'mask with no stored secret is treated as not provided';
};

done_testing();
