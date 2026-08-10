package Koha::Plugin::Com::ByWaterSolutions::WebhookNotifications;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Log qw(logaction);
use Koha::AuthorisedValues;
use Koha::DateUtils qw(dt_from_string);

use Data::Dumper;
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use List::Util qw(any);
use Log::Log4perl qw(:easy);
use LWP::UserAgent;
use IO::Compress::Gzip qw(gzip $GzipError);
use Mojo::JSON qw(encode_json decode_json);
use POSIX;
use Try::Tiny;
use YAML::XS qw(Load);

our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

# Placeholder shown in the configure form's client_secret field. The real
# secret is never sent to the browser; if this value comes back on save it
# means the user did not retype the secret, so the stored value must be kept.
our $MASKED_SECRET_PLACEHOLDER = '••••••••••••';

our $metadata = {
    name            => 'Webhook Notifications',
    author          => 'Samuel Mahr',
    date_authored   => '2025-12-09',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Plugin to forward messages to a webhook endpoint for processing and sending',
};

our $instance = C4::Context->config('database');
$instance =~ s/koha_//;

# Cache for OAuth2 credentials to avoid redundant DB reads and decryption
our $oauth_credentials_cache;

our $default_archive_dir = C4::Context->config('webhook_archive_path') || "/var/lib/koha/$instance/webhook_notifications_archive";

=head3 new

=cut

sub new {
    my ($class, $args) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

=head3 configure

=cut

sub configure {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    unless ($cgi->param('save')) {
        my $template = $self->get_template({file => 'configure.tt'});

        $template->param(
            archive_dir                        => $self->retrieve_data('archive_dir') || $default_archive_dir,
            payload_format                     => $self->retrieve_data('payload_format') || 'full',
            skip_odue_if_other_if_sms_or_email => $self->retrieve_data('skip_odue_if_other_if_sms_or_email'),
            has_oauth_credentials             => $self->has_oauth_credentials(),
            auth_url                           => $self->get_display_auth_url(),
            client_id                          => $self->get_display_client_id(),
            client_secret                      => $MASKED_SECRET_PLACEHOLDER,
            notice_url                         => $self->get_display_notice_url(),
            customer_id                        => $self->get_display_customer_id(),
        );

        $self->output_html($template->output());
    } else {
        # Save plugin-specific settings
        $self->store_data({
            archive_dir                        => $cgi->param('archive_dir'),
            payload_format                     => $cgi->param('payload_format'),
            skip_odue_if_other_if_sms_or_email => $cgi->param('skip_odue_if_other_if_sms_or_email'),
        });

        # Save encrypted credentials if provided
        my $auth_url      = $cgi->param('auth_url');
        my $client_id     = $cgi->param('client_id');
        my $client_secret = $cgi->param('client_secret');
        my $notice_url    = $cgi->param('notice_url');
        my $customer_id   = $cgi->param('customer_id');

        # The configure form pre-fills the secret field with a masked
        # placeholder, never the real secret. If the user saves without
        # retyping it (e.g. while changing an unrelated setting), keep the
        # stored secret instead of overwriting it with the placeholder.
        my $stored_syspref = $self->get_decrypted_syspref('WebhookCredentials');
        $client_secret     = _resolve_client_secret(
            $client_secret,
            $stored_syspref ? $stored_syspref->{client_secret} : undef,
        );

        if ($auth_url && $client_id && $client_secret && $notice_url) {
            my $credentials = {
                auth_url      => $auth_url,
                client_id     => $client_id,
                client_secret => $client_secret,
                notice_url    => $notice_url,
                customer_id   => $customer_id // '',
            };

            $self->set_encrypted_syspref('WebhookCredentials', $credentials );
            INFO("OAuth credentials configured via system preference");
        } else {
            # Invalidate cache if credentials were cleared
            if (defined $cgi->param('auth_url') || defined $cgi->param('client_id') ||
                defined $cgi->param('client_secret') || defined $cgi->param('notice_url')) {
                $self->invalidate_oauth_credentials_cache();
                INFO("OAuth credentials cache invalidated");
            }

            # If any credential field is provided, validate required fields
            if ($auth_url || $client_id || $client_secret || $notice_url) {
                unless ($auth_url && $client_id && $client_secret && $notice_url) {
                    # Partial credentials provided - show error
                    my $template = $self->get_template({file => 'configure.tt'});
                    $template->param(
                        archive_dir                        => $self->retrieve_data('archive_dir') || $default_archive_dir,
                        payload_format                     => $self->retrieve_data('payload_format') || 'full',
                        skip_odue_if_other_if_sms_or_email => $self->retrieve_data('skip_odue_if_other_if_sms_or_email'),
                        has_oauth_credentials             => $self->has_oauth_credentials(),
                        auth_url                           => $auth_url // '',
                        client_id                          => $client_id // '',
                        client_secret                      => $MASKED_SECRET_PLACEHOLDER,
                        notice_url                         => $notice_url // '',
                        customer_id                        => $customer_id // '',
                        error_message => 'All OAuth2 credential fields are required. Please provide auth_url, client_id, client_secret, and notice_url.',
                    );
                    $self->output_html($template->output());
                    return;
                }
            }
        }

        $self->go_home();
    }
}

=head3 _resolve_client_secret

Given the client_secret submitted from the configure form and the secret
currently stored, return the value that should be persisted. The form pre-fills
the secret field with a masked placeholder rather than the real secret, so a
submission equal to the placeholder (or empty/undef) means "unchanged" and the
stored secret is kept. Any other value is a genuinely new secret.

=cut

sub _resolve_client_secret {
    my ($submitted, $existing) = @_;

    return $existing
        if !defined $submitted
        || $submitted eq ''
        || $submitted eq $MASKED_SECRET_PLACEHOLDER;

    return $submitted;
}

=head3 install

This is the 'install' method. Any database tables or other setup that should
be done when the plugin if first installed should be executed in this method.
The installation method should always return true if the installation succeeded
or false if it failed.

=cut

sub install() {
    my ($self, $args) = @_;

    unless (-d $default_archive_dir) {
        make_path($default_archive_dir) or die "Failed to create path '$default_archive_dir': $!";
    }

    # Migrate credentials from koha-conf.xml to system preference
    $self->migrate_credentials_from_koha_conf();

    return 1;
}

=head3 upgrade

This is the 'upgrade' method. It will be triggered when a newer version of a
plugin is installed over an existing older version of a plugin

=cut

sub upgrade {
    my ($self, $args) = @_;

    # Check if migration is needed (only run once)
    unless (C4::Context->preference('WebhookCredentials')) {
        $self->migrate_credentials_from_koha_conf();
    }

    return 1;
}

=head3 migrate_credentials_from_koha_conf

Migrates OAuth2 credentials from koha-conf.xml to encrypted system preference.
This method runs automatically during install and upgrade.

=cut

sub migrate_credentials_from_koha_conf {
    my ($self) = @_;

    # Check if already migrated
    return if C4::Context->preference('WebhookCredentials');

    # Check if credentials exist in koha-conf.xml
    my $auth_url      = C4::Context->config('webhook_auth_url');
    my $client_id     = C4::Context->config('webhook_client_id');
    my $client_secret = C4::Context->config('webhook_client_secret');
    my $notice_url    = C4::Context->config('webhook_notice_url');
    my $customer_id   = C4::Context->config('webhook_customer_id');

    unless ($auth_url && $client_id && $client_secret && $notice_url) {
        return;  # No credentials to migrate
    }

    # Encrypt and store as system preference
    my $credentials = {
        auth_url      => $auth_url,
        client_id     => $client_id,
        client_secret => $client_secret,
        notice_url    => $notice_url,
        customer_id   => $customer_id // '',
    };

    $self->set_encrypted_syspref('WebhookCredentials', $credentials );

    INFO("Migrated OAuth credentials from koha-conf.xml to system preference");
}

=head3 uninstall

This method will be run just before the plugin files are deleted
when a plugin is uninstalled. It is good practice to clean up
after ourselves!

=cut

sub uninstall() {
    my ($self, $args) = @_;

    return 1;
}

=head3 get_oauth_token

Fetches an OAuth2 access token using client credentials flow.

Credentials are retrieved from system preference first, with fallback to koha-conf.xml.

=cut

sub get_oauth_token {
    my ($self) = @_;

    my $credentials = $self->get_oauth_credentials();
    die "No OAuth credentials configured. Please configure webhook OAuth credentials in the plugin settings or koha-conf.xml."
        unless $credentials;

    my $auth_url      = $credentials->{auth_url};
    my $client_id     = $credentials->{client_id};
    my $client_secret = $credentials->{client_secret};

    unless ($auth_url && $client_id && $client_secret) {
        die "Missing required OAuth credentials: auth_url, client_id, client_secret";
    }

    my $ua = LWP::UserAgent->new(timeout => 30);

    my $response = $ua->post(
        $auth_url,
        Content_Type => 'application/x-www-form-urlencoded',
        Content      => [
            client_id     => $client_id,
            client_secret => $client_secret,
            grant_type    => 'client_credentials',
        ],
    );

    unless ($response->is_success) {
        die "OAuth token request failed: " . $response->status_line . " - " . $response->decoded_content;
    }

    my $token_data = decode_json($response->decoded_content);

    unless ($token_data->{access_token}) {
        die "OAuth response did not contain access_token";
    }

    return $token_data->{access_token};
}

=head3 send_to_webhook

Sends notice data to the configured webhook endpoint.

=cut

sub send_to_webhook {
    my ($self, $params) = @_;

    my $credentials = $self->get_oauth_credentials();
    die "No OAuth credentials configured. Cannot send to webhook."
        unless $credentials;

    my $notice_url  = $credentials->{notice_url};
    my $customer_id = $credentials->{customer_id};
    my $token       = $params->{token};
    my $payload     = $params->{payload};

    unless ($notice_url) {
        die "Missing notice_url in OAuth credentials";
    }

    my $ua = LWP::UserAgent->new(timeout => 60);

    my $json      = encode_json($payload);
    my $threshold = 3 * 1024 * 1024;    # 3MB, half the 6MB Lambda event limit

    my @headers = ( 'Authorization' => "Bearer $token" );
    if ($customer_id) {
        push @headers, 'customer-id' => $customer_id;
    }

    my $body;
    if ( length($json) > $threshold ) {    # encode_json returns UTF-8 bytes
        # gzip and send raw bytes; API Gateway base64s binary content-types
        gzip( \$json => \my $gz ) or die "gzip failed: $GzipError";
        push @headers, 'Content-Type' => 'application/octet-stream';
        push @headers, 'Content-Encoding' => 'gzip';
        $body = $gz;
    }
    else {
        push @headers, 'Content-Type' => 'application/json';
        $body = $json;
    }

    my $response = $ua->post(
        $notice_url,
        @headers,
        Content => $body,
    );

    return {
        success      => $response->is_success,
        status_code  => $response->code,
        status_line  => $response->status_line,
        content      => $response->decoded_content,
    };
}

=head3 load_yaml_documents_from_message_content

Parses YAML from message C<content>. Koha digest notices wrap repeating blocks
in lines of four or more dashes (C<---->); the full body is often not valid
YAML as a single document, so when those delimiters are present we load each
segment separately. Segments that are only comma-separated numeric ids (one
or more lines) are collected and merged with the header mapping in
C<merge_webhook_yaml_documents>. Multi-document YAML without digest delimiters
is still supported. Message content is normalized first (see
C<_normalize_yaml_flat_id_list_blocks>).

=cut

sub load_yaml_documents_from_message_content {
    my ( $self, $content ) = @_;
    my @docs;
    my @orphans;
    return ( \@docs, \@orphans ) unless defined $content && length $content;

    $content = _strip_pound_comments_and_continuations($content);
    $content = _normalize_yaml_flat_id_list_blocks($content);

    if ( $content =~ /\R-{4,}\R/ ) {
        for my $seg ( split( /\R-{4,}\R/, $content ) ) {
            $seg =~ s/\A\s+|\s+\z//g;
            next unless length $seg;
            $seg = _normalize_yaml_flat_id_list_blocks($seg);
            if ( _segment_is_plain_id_list_block($seg) ) {
                push @orphans, $seg;
                next;
            }
            eval {
                my @loaded = Load($seg);
                push @docs, grep { defined && ref $_ eq 'HASH' } @loaded;
            };
        }
    }

    if ( !@docs ) {
        eval {
            my @loaded = Load($content);
            push @docs, grep { defined && ref $_ eq 'HASH' } @loaded;
        };
    }

    return ( \@docs, \@orphans );
}

=head3 merge_webhook_yaml_documents

When digest or multi-document YAML yields several mappings with C<webhook: yes>,
merge them into one mapping so checkout/hold identifiers are combined and only
one webhook POST is sent per message. Plain id-only digest segments (lines of
comma-separated numbers) attach to C<checkouts> when any document declares a
C<checkouts> key, to C<holds> when any document declares C<holds>, or to
C<old_checkouts> when any document declares C<old_checkouts> (even if the value
is empty before digest rows are expanded). Merged old-checkout ids are emitted
under the plural C<old_checkouts>; the singular C<old_checkout> is still read.

=cut

sub merge_webhook_yaml_documents {
    my ( $self, $docs, $orphans ) = @_;
    $docs    = [] unless ref $docs    eq 'ARRAY';
    $orphans = [] unless ref $orphans eq 'ARRAY';

    my @wh = grep { ( $_->{webhook} // '' ) eq 'yes' } @$docs;
    return undef unless @wh;

    my $capture_checkouts     = any { exists $_->{checkouts} } @wh;
    my $capture_holds         = any { exists $_->{holds} } @wh;
    my $capture_old_checkouts = any { exists $_->{old_checkouts} } @wh;

    my @orphan_ids;
    for my $seg ( @$orphans ) {
        push @orphan_ids, _split_trim_ids($seg);
    }

    return $wh[0] if @wh == 1 && !@orphan_ids;

    my %m = ( webhook => 'yes' );
    my ( @c_ids, @h_ids, @oc_ids, @oh_ids );

    if (@orphan_ids) {
        if ($capture_checkouts) {
            push @c_ids, @orphan_ids;
        }
        elsif ($capture_holds) {
            push @h_ids, @orphan_ids;
        }
        elsif ($capture_old_checkouts) {
            push @oc_ids, @orphan_ids;
        }
    }

    for my $y (@wh) {
        push @c_ids,  _split_trim_ids( $y->{checkouts} )     if $y->{checkouts};
        push @c_ids,  _split_trim_ids( $y->{checkout} )      if $y->{checkout};
        push @h_ids,  _split_trim_ids( $y->{holds} )         if $y->{holds};
        push @h_ids,  _split_trim_ids( $y->{hold} )          if $y->{hold};
        push @oc_ids, _split_trim_ids( $y->{old_checkouts} ) if $y->{old_checkouts};
        push @oc_ids, _split_trim_ids( $y->{old_checkout} )  if $y->{old_checkout};
        push @oh_ids, _split_trim_ids( $y->{old_hold} )      if $y->{old_hold};

        $m{patron}     //= $y->{patron};
        $m{library}    //= $y->{library};
        $m{item}       //= $y->{item};
        $m{biblio}     //= $y->{biblio};
        $m{biblioitem} //= $y->{biblioitem};
    }

    @c_ids  = _uniq_preserving_order(@c_ids);
    @h_ids  = _uniq_preserving_order(@h_ids);
    @oc_ids = _uniq_preserving_order(@oc_ids);
    @oh_ids = _uniq_preserving_order(@oh_ids);

    $m{checkouts}     = join( ',', @c_ids )  if @c_ids;
    $m{holds}         = join( ',', @h_ids )  if @h_ids;
    $m{old_checkouts} = join( ',', @oc_ids ) if @oc_ids;
    $m{old_hold}      = join( ',', @oh_ids ) if @oh_ids;

    return \%m;
}

sub _segment_is_plain_id_list_block {
    my ($seg) = @_;
    return 0 unless defined $seg && $seg =~ /\S/;
    for my $line ( split /\R/, $seg ) {
        next unless $line =~ /\S/;
        return 0 unless _line_is_digit_csv($line);
    }
    return 1;
}

sub _line_is_digit_csv {
    my ($line) = @_;
    $line =~ s/\A\s+|\s+\z//g;
    return 0 unless length $line;
    for my $field ( split /\s*,\s*/, $line ) {
        return 0 unless $field =~ /^\d+$/;
    }
    return 1;
}

sub _split_trim_ids {
    my ($s) = @_;
    return () unless defined $s && length $s;
    return map { s/\A\s+|\s+\z//gr } grep { length } split /,/, $s;
}

sub _uniq_preserving_order {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

sub _cancellation_reason_label {
    my ($code) = @_;
    return undef unless defined $code && length $code;
    my $av = Koha::AuthorisedValues->search({
        category         => 'HOLD_CANCELLATION',
        authorised_value => $code,
    })->next;
    return $av ? $av->lib : $code;
}

=head3 before_send_messages

Plugin hook that runs right before the message queue is processed
in process_message_queue.pl

=cut

sub before_send_messages {
    my ($self, $params) = @_;

    my $is_cronjob = $0 =~ /process_message_queue.pl$/;

    logaction('WEBHOOK_NOTIFICATIONS', 'STARTED', undef, undef, 'cron') if $is_cronjob;

    if (ref($params->{type}) eq 'ARRAY' && grep(/^skip_webhook$/, @{$params->{type}})) {
        logaction('WEBHOOK_NOTIFICATIONS', 'SKIPPED', undef, undef, 'cron') if $is_cronjob;
        return;
    }

    my $test_mode = C4::Context->config('webhook_test_mode');
    my $verbose   = C4::Context->config('webhook_verbose') || $params->{verbose};

    my $library_name = C4::Context->preference('LibraryName');
    $library_name =~ s/ /_/g;
    my $dir      = tempdir(CLEANUP => 0);
    my $ts       = strftime("%Y-%m-%dT%H-%M-%S", gmtime(time()));
    my $filename = "$ts-Notices-$library_name.json";
    my $realpath = "$dir/$filename";

    my $archive_dir = $self->retrieve_data('archive_dir') || $default_archive_dir;
    my $payload_format = $self->retrieve_data('payload_format') || 'full';

    my $info = {
        archive_dir    => $archive_dir,
        test_mode      => $test_mode,
        library_name   => $library_name,
        timestamp      => $ts,
        filename       => $filename,
        filepath       => $realpath,
        payload_format => $payload_format,
    };

    Log::Log4perl->easy_init({level => $DEBUG, file => ">>$archive_dir/$ts-Notices-$library_name.log"});
    $is_cronjob && say "WEBHOOK - LOG WRITTEN TO $archive_dir/$ts-Notices-$library_name.log";

    INFO("Running WebhookNotifications before_send_messages hook");

    if ($archive_dir) {
        unless (-d $archive_dir) {
            make_path $archive_dir or die "Failed to create path: $archive_dir";
        }

        if (-d $archive_dir) {
            my $dt = dt_from_string();
            $dt->subtract(days => 30);
            my $age_threshold = $dt->datetime;
            my $dirh;
            try {
                opendir $dirh, $archive_dir or die "Cannot open directory: $!";
            } catch {
                $info->{error_message} = $_;
                logaction('WEBHOOK_NOTIFICATIONS', 'CREATE_DIR_FAILED', undef, encode_json($info), 'cron') if $is_cronjob;
                die "Cannot open directory $archive_dir: $_";
            };
            my @files = readdir $dirh;
            closedir $dirh;

            foreach my $f (@files) {
                next unless $f =~ /log|json$/;
                my $filepath = "$archive_dir/$f";
                my $file_mtime = (stat($filepath))[9];
                if ($file_mtime && $file_mtime < $dt->epoch) {
                    unlink($filepath);
                }
            }
        }
    }

    $is_cronjob && say "WEBHOOK - TEST MODE" if $test_mode;
    INFO("TEST MODE IS ENABLED") if $test_mode;

    my $search_params = {status => 'pending', content => {-like => '%webhook: yes%'}};

    my $message_id = $params->{message_id};
    $search_params->{message_id} = $message_id if $message_id;

    # 22.11.00, 22.05.8, 21.11.14 +, bug 27265
    $search_params->{message_transport_type} = $params->{type}
        if ref($params->{type}) eq 'ARRAY' && scalar @{$params->{type}} && $params->{type}->[0] ne 'webhook';

    # Older versions of Koha
    $search_params->{message_transport_type} = $params->{type}
        if ref($params->{type}) eq q{} && $params->{type} && $params->{type} ne 'webhook';

    # 22.11.00, 22.05.8, 21.11.14 +, bug 27265
    $search_params->{letter_code} = $params->{letter_code}
        if ref($params->{letter_code}) eq 'ARRAY' && scalar @{$params->{letter_code}};

    # Older versions of Koha
    $search_params->{letter_code} = $params->{letter_code}
        if ref($params->{letter_code}) eq q{} && $params->{letter_code};

    $is_cronjob && say "WEBHOOK - SEARCH PARAMETERS: " . Data::Dumper::Dumper($search_params) if $verbose;
    INFO("SEARCH PARAMETERS: " . Data::Dumper::Dumper($search_params));
    $info->{search_params} = $search_params;

    my $other_params = {};
    $other_params->{rows} = $params->{limit} if $params->{limit};
    $is_cronjob && say "OTHER PARAMETERS: " . Data::Dumper::Dumper($other_params);
    INFO("OTHER PARAMETERS: " . Data::Dumper::Dumper($other_params));
    $info->{other_params}         = $other_params;
    $info->{total_messages_count} = 0;

    my $results = {sent => 0, failed => 0};
    my @message_data;
    my $messages_seen      = {};
    my $messages_generated = 0;

    my $skip_odue_if_other_if_sms_or_email = $self->retrieve_data('skip_odue_if_other_if_sms_or_email');
    my $dbh = C4::Context->dbh;
    my $letter1 = $dbh->selectcol_arrayref(q{SELECT DISTINCT(letter1) FROM overduerules});
    my $letter2 = $dbh->selectcol_arrayref(q{SELECT DISTINCT(letter2) FROM overduerules});
    my $letter3 = $dbh->selectcol_arrayref(q{SELECT DISTINCT(letter3) FROM overduerules});
    my @odue_letter_codes = (@$letter1, @$letter2, @$letter3);

    # Get OAuth token once for this batch
    my $oauth_token;
    unless ($test_mode) {
        try {
            $oauth_token = $self->get_oauth_token();
            INFO("Successfully obtained OAuth token");
        } catch {
            $is_cronjob && say "WEBHOOK - ERROR - Failed to get OAuth token: $_";
            ERROR("Failed to get OAuth token: $_");
            $info->{oauth_error} = $_;
            logaction('WEBHOOK_NOTIFICATIONS', 'OAUTH_FAILED', undef, encode_json($info), 'cron') if $is_cronjob;
            return;
        };
    }

    my @messages = Koha::Notice::Messages->search($search_params, $other_params)->as_list;
    INFO("FOUND " . scalar @messages . " MESSAGES TO PROCESS");

    if (scalar @messages) {

        $info->{total_messages_count} += scalar @messages;

        unless ($test_mode) {
            foreach my $m (@messages) {
                $m->update({status => 'deleted'});
            }
        }

        foreach my $m (@messages) {
            $info->{results}->{types}->{$m->letter_code}->{$m->message_transport_type}++;

            try {
                $is_cronjob && say "WEBHOOK - WORKING ON MESSAGE " . $m->id if $verbose;
                INFO("WORKING ON MESSAGE " . $m->id);
                $is_cronjob && say "WEBHOOK - CONTENT:\n" . $m->content if $verbose > 2;
                TRACE("MESSAGE CONTENTS: " . Data::Dumper::Dumper($m->unblessed));
                my $content = $m->content();
                my ( $docs, $orphans ) = $self->load_yaml_documents_from_message_content($content);
                my $yaml    = $self->merge_webhook_yaml_documents( $docs, $orphans );

                unless ($yaml) {
                    INFO("MESSAGE ${\($m->id)} skipped - no webhook: yes YAML in content");
                    next;
                }

                my $patron;

                try {

                        $messages_seen->{$m->message_id} = 1;

                        my $data;
                        $data->{message} = $self->scrub_message($m->unblessed);

                        # Handle patron key first in case old checkouts or holds have been anonymized
                        try {
                            $patron         //= Koha::Patrons->find($yaml->{patron}) if $yaml->{patron};
                            $data->{patron} //= $self->scrub_patron($patron->unblessed) if $patron;
                        } catch {
                            $is_cronjob && say "WEBHOOK - Fetching patron failed - $_";
                        };

                        ## Handle 'checkout' / 'old_checkout' / 'old_checkouts'
                        ## Any of them may hold a merged comma-separated id list.
                        my @checkout_objects;
                        if ($yaml->{checkout}) {
                            push @checkout_objects,
                                grep { $_ }
                                map  { Koha::Checkouts->find($_) }
                                _split_trim_ids( $yaml->{checkout} );
                        }
                        for my $old_key (qw( old_checkout old_checkouts )) {
                            next unless $yaml->{$old_key};
                            push @checkout_objects,
                                grep { $_ }
                                map  { Koha::Old::Checkouts->find($_) }
                                _split_trim_ids( $yaml->{$old_key} );
                        }
                        foreach my $checkout (@checkout_objects) {
                            $patron           //= $checkout->patron;
                            $data->{patron}   = $self->scrub_patron($patron->unblessed);
                            $data->{library} //= $checkout->library->unblessed;

                            my $subdata;
                            my $item = $checkout->item;
                            $subdata->{checkout}   = $checkout->unblessed;
                            $subdata->{item}       = $item->unblessed;
                            $subdata->{biblio}     = $self->scrub_biblio($item->biblio->unblessed);
                            $subdata->{biblioitem} = $item->biblioitem->unblessed;
                            $subdata->{itemtype}   = $item->itemtype->unblessed;

                            $data->{checkouts} //= [];
                            push( @{$data->{checkouts}}, $subdata );
                        }

                        ## Handle 'checkouts'
                        if ($yaml->{checkouts}) {
                            my @checkouts = _split_trim_ids( $yaml->{checkouts} );

                            foreach my $id (@checkouts) {
                                my $checkout = Koha::Checkouts->find($id);
                                next unless $checkout;

                                $patron //= $checkout->patron;
                                $data->{patron} //= $self->scrub_patron($patron->unblessed);

                                my $subdata;
                                my $item = $checkout->item;
                                $subdata->{checkout}   = $checkout->unblessed;
                                $subdata->{library}    = $checkout->library->unblessed;
                                $subdata->{item}       = $item->unblessed;
                                $subdata->{biblio}     = $self->scrub_biblio($item->biblio->unblessed);
                                $subdata->{biblioitem} = $item->biblioitem->unblessed;
                                $subdata->{itemtype}   = $item->itemtype->unblessed;

                                $data->{checkouts} //= [];
                                push(@{$data->{checkouts}}, $subdata);
                            }
                        }

                        ## Handle 'hold'
                        if ($yaml->{hold}) {
                            my $hold = Koha::Holds->find($yaml->{hold});
                            $m->update({status => 'failed', failure_code => "Hold with id $yaml->{hold} not found"}) && next unless $hold;

                            my $biblio = $hold->biblio;
                            $m->update({status => 'failed', failure_code => "Bib for hold with id $yaml->{hold} not found"}) && next unless $biblio;

                            my $biblioitem = $biblio->biblioitem;
                            $m->update({status => 'failed', failure_code => "Bib item for hold with id $yaml->{hold} not found"}) && next unless $biblioitem;

                            $patron //= $hold->patron;
                            $data->{patron} //= $self->scrub_patron($patron->unblessed);

                            my $subdata;
                            $subdata->{hold}           = $hold->unblessed;
                            $subdata->{hold}->{cancellation_reason_description}
                                = _cancellation_reason_label($hold->cancellation_reason);
                            $subdata->{pickup_library} = $hold->branch->unblessed;
                            $subdata->{biblio}         = $self->scrub_biblio($biblio->unblessed);
                            $subdata->{biblioitem}     = $biblioitem->unblessed;

                            if (my $item = $hold->item) {
                                $subdata->{item}     = $item->unblessed;
                                $subdata->{itemtype} = $item->itemtype->unblessed;
                            }

                            $data->{holds} = [$subdata];
                        }

                        ## Handle 'old_hold'
                        if ($yaml->{old_hold}) {
                            my $hold = Koha::Old::Holds->find($yaml->{old_hold});
                            $m->update({status => 'failed', failure_code => "Hold with id $yaml->{old_hold} not found"}) && next unless $hold;

                            my $biblio = Koha::Biblios->find($hold->biblionumber);
                            $m->update({status => 'failed', failure_code => "Bib for old hold with id $yaml->{old_hold} not found"}) && next unless $biblio;

                            my $biblioitem = $biblio->biblioitem;
                            $m->update({status => 'failed', failure_code => "Bib for old hold with id $yaml->{old_hold} not found"}) && next unless $biblioitem;

                            $patron //= $hold->patron;
                            $data->{patron} //= $self->scrub_patron($patron->unblessed);

                            my $hold_data = $hold->unblessed;
                            $hold_data->{cancellation_reason_description}
                                = _cancellation_reason_label($hold->cancellation_reason);

                            my $subdata;
                            $subdata->{holds}          = [$hold_data];
                            $subdata->{pickup_library} = Koha::Libraries->find($hold->branchcode);
                            $subdata->{biblio}         = $self->scrub_biblio($biblio->unblessed);
                            $subdata->{biblioitem}     = $biblioitem->unblessed;

                            if (my $item = $hold->item) {
                                $subdata->{item}     = $item->unblessed;
                                $subdata->{itemtype} = $item->itemtype->unblessed;
                            }

                            $data->{holds} = [$subdata];
                        }

                        ## Handle 'holds'
                        if ($yaml->{holds}) {
                            my @holds = _split_trim_ids( $yaml->{holds} );

                            foreach my $id (@holds) {
                                my $hold = Koha::Holds->find($id);
                                next unless $hold;

                                $patron //= $hold->patron;
                                $data->{patron} //= $self->scrub_patron($patron->unblessed);

                                my $subdata;
                                my $item = $hold->item;
                                $subdata->{hold}           = $hold->unblessed;
                                $subdata->{hold}->{cancellation_reason_description}
                                    = _cancellation_reason_label($hold->cancellation_reason);
                                $subdata->{pickup_library} = $hold->branch->unblessed;
                                if ($item) {
                                    $subdata->{item}       = $item->unblessed;
                                    $subdata->{itemtype}   = $item->itemtype->unblessed;
                                    $subdata->{biblio}     = $self->scrub_biblio($item->biblio->unblessed);
                                    $subdata->{biblioitem} = $item->biblioitem->unblessed;
                                }

                                $data->{holds} //= [];
                                push(@{$data->{holds}}, $subdata);
                            }
                        }

                        ## Handle misc key/value pairs
                        try {
                            $data->{library} ||= Koha::Libraries->find($yaml->{library})->unblessed if $yaml->{library};
                        } catch {
                            $is_cronjob && say "WEBHOOK - Fetching library failed - $_";
                        };

                        try {
                            $data->{item} ||= Koha::Items->find($yaml->{item})->unblessed if $yaml->{item};
                        } catch {
                            $is_cronjob && say "WEBHOOK - Fetching item failed - $_";
                        };

                        try {
                            $data->{biblio} ||= $self->scrub_biblio(Koha::Biblios->find($yaml->{biblio})->unblessed)
                                if $yaml->{biblio};
                        } catch {
                            $is_cronjob && say "WEBHOOK - Fetching biblio failed - $_";
                        };

                        try {
                            $data->{biblioitem} ||= Koha::Biblioitems->find($yaml->{biblioitem})->unblessed
                                if $yaml->{biblioitem};
                        } catch {
                            $is_cronjob && say "WEBHOOK - Fetching biblioitem failed - $_";
                        };

                        try {
                            $data->{patron}->{account_balance} = $patron->account->balance if $patron;
                        } catch {
                            $is_cronjob && say "WEBHOOK - Fetching patron account balance failed - $_";
                        };

                        # If enabled, skip sending if this is an overdue notice *and* the patron has an sms number or email address
                        if ($m->message_transport_type eq 'phone' && $skip_odue_if_other_if_sms_or_email && any { $m->{letter_code} eq $_ } @odue_letter_codes) {
                            my $skip = $patron->notice_email_address || $patron->smsalertnumber;

                            if ($skip) {
                                $m->status('deleted');
                                $m->failure_code('Patron already received a notification via another channel.');
                                $m->update();
                                next;
                            }
                        }

                        if (keys %$data) {
                            # Prepare payload based on format setting
                            my $webhook_payload;
                            if ($payload_format eq 'minimal') {
                                $webhook_payload = $self->build_minimal_payload($data, $yaml);
                            } else {
                                $webhook_payload = $data;
                            }

                            # Send to webhook (unless test mode)
                            my $webhook_success = 1;
                            unless ($test_mode) {
                                my $webhook_result = $self->send_to_webhook({
                                    token   => $oauth_token,
                                    payload => $webhook_payload,
                                });

                                if ($webhook_result->{success}) {
                                    INFO("MESSAGE ${\($m->id)} sent to webhook successfully");
                                } else {
                                    $webhook_success = 0;
                                    $is_cronjob && say "WEBHOOK - ERROR - Webhook request failed: $webhook_result->{status_line}";
                                    ERROR("Webhook request failed for message ${\($m->id)}: $webhook_result->{status_line}");
                                }
                            }

                            if ($webhook_success) {
                                $m->update({status => 'sent'}) unless $test_mode;
                                $messages_generated++;
                                push(@message_data, $webhook_payload);
                                $is_cronjob && say "WEBHOOK - MESSAGE DATA: " . Data::Dumper::Dumper($webhook_payload) if $verbose > 1;
                                $results->{sent}++;
                                INFO("MESSAGE ${\($m->id)} SENT");
                                $info->{results}->{sent}->{successful}++;
                            } else {
                                $m->update({status => 'failed', failure_code => 'WEBHOOK_FAILED'}) unless $test_mode;
                                $results->{failed}++;
                                $info->{results}->{sent}->{failed}++;
                            }
                        } else {
                            $m->update({status => 'failed', failure_code => 'NO DATA'}) unless $test_mode;
                            $results->{failed}++;
                            $info->{results}->{sent}->{failed}++;
                            INFO("MESSAGE ${\($m->id)} FAILED");
                        }
                    } catch {
                        $is_cronjob && say "WEBHOOK - ERROR - Processing Message ${\( $m->id )} Failed - $_";
                        ERROR("Processing Message ${\( $m->id )} Failed - $_");
                        $m->status('failed');
                        $m->failure_code("ERROR: $_");
                        $m->update() unless $test_mode;
                        $info->{results}->{sent}->{failed}++;
                        $results->{failed}++;
                    };
            } catch {
                $is_cronjob && say "WEBHOOK - ERROR - Processing Message ${\( $m->id )} Failed - $_";
                ERROR("Processing Message ${\( $m->id )} Failed - $_");
                $m->status('failed');
                $m->failure_code("ERROR: $_");
                $m->update() unless $test_mode;
                $info->{results}->{sent}->{failed}++;
                $results->{failed}++;
            };

            INFO("FINISHED PROCESSING MESSAGE " . $m->id);
        }
    }

    my $dev_version = '{' . 'VERSION' . '}';
    my $v           = $VERSION eq $dev_version ? "DEVELOPMENT VERSION" : $VERSION;
    my $json        = encode_json({
        json_structure_version => '3',
        webhook_plugin_version => $v,
        payload_format         => $payload_format,
        messages               => \@message_data,
    });

    if ($archive_dir) {
        my $archive_path = $archive_dir . "/$filename";
        write_file($archive_path, $json);
        $is_cronjob && say "WEBHOOK - FILE WRITTEN TO $archive_path";
        INFO("WEBHOOK - FILE WRITTEN TO $archive_path");
    }

    logaction('WEBHOOK_NOTIFICATIONS', 'DONE', undef, undef, 'cron') if $is_cronjob;
    logaction('WEBHOOK_NOTIFICATIONS', 'MESSAGES_PROCESSED', undef, encode_json($info), 'cron') if $is_cronjob;
}

=head3 _strip_pound_comments_and_continuations

Some notice templates emit invalid YAML where free-text annotations are added
as C<#>-prefixed lines that wrap to subsequent un-prefixed continuation lines.
MessageBee-style notices look like:

  webhook: yes
  holds:
  #Title Small country houses: their repair and enlargement; forty examples
  chosen from five centuries Weaver, Lawrence
  1209903, #Title Fast like a girl: a woman's guide to using the healing power of
  burn fat, boost energy, and balance hormones Pelz, Mindy
  1209902,
  #Title The naked gun DVD gift

YAML's native C<#> handling only covers the first line of a wrapped comment;
the un-prefixed continuation lines get parsed as data and break C<YAML::XS::Load>
(typically because they reintroduce stray colons or unquoted text).

This helper strips:

=over

=item * whole-line C<#> comments (optionally indented);

=item * inline C<#> comments on id-list lines (e.g. C<1209903, #Title ...>);

=item * any subsequent prose continuation lines, up to the next structural
YAML line (blank line, digest delimiter C<---->, known plugin key like
C<webhook:>, C<patron:>, C<holds:>, or a bare numeric id line).

=back

Run before L</_normalize_yaml_flat_id_list_blocks> so the flat-id normalizer
sees clean input.

=cut

sub _strip_pound_comments_and_continuations {
    my ($text) = @_;
    return $text unless defined $text && length $text;

    my @KEYS = qw(
        webhook patron library item biblio biblioitem
        holds hold checkouts checkout old_checkout old_checkouts old_hold
    );
    my $key_re = join '|', map { quotemeta $_ } @KEYS;

    my @lines = split /\R/, $text, -1;
    my @out;
    my $in_comment_block = 0;

    for my $line (@lines) {
        my $is_structural =
               $line =~ /^\s*$/
            || $line =~ /^-{3,}\s*$/
            || $line =~ /^\s*(?:$key_re)\s*:/
            || $line =~ /^\s*\d+\s*,?\s*$/;

        if ( $line =~ /^\s*#/ ) {
            $in_comment_block = 1;
            next;
        }

        if ( $line =~ /^(\s*\d+\s*,?)\s+#.*$/ ) {
            push @out, $1;
            $in_comment_block = 1;
            next;
        }

        if ($in_comment_block) {
            if ($is_structural) {
                $in_comment_block = 0;
                push @out, $line;
            }
            next;
        }

        push @out, $line;
    }

    return join "\n", @out;
}

=head3 _normalize_yaml_flat_id_list_blocks

Some notice templates emit invalid YAML where comma-separated identifiers are
placed on their own lines after an otherwise empty mapping value, e.g.:

  webhook: yes
  holds:
  2,
  1,

C<YAML::XS::Load> rejects that. Collapse those runs into a single line
C<holds: 2,1> so parsing and the rest of this plugin behave as for a
one-line list. Optional blank lines between the key and the first id line are
skipped. Only non-negative integer ids are recognized (same as typical Koha
primary keys).

Applied to every comma-separated id field this plugin reads from YAML.
Called from L</load_yaml_documents_from_message_content> on the full message
and again on each digest segment after C<----> splitting.

=cut

sub _normalize_yaml_flat_id_list_blocks {
    my ($text) = @_;
    return $text unless defined $text && length $text;

    my @KEYS = qw( holds hold checkouts checkout old_checkout old_checkouts old_hold );
    my $key_re = join '|', map { quotemeta $_ } @KEYS;

    my @lines = split /\R/, $text, -1;
    my @out;
    my $i = 0;
    LINE:
    while ( $i < @lines ) {
        my $line = $lines[$i];
        if ( $line =~ /^($key_re):\s*$/ ) {
            my $key    = $1;
            my $cursor = $i + 1;
            while ( $cursor < @lines && $lines[$cursor] =~ /^\s*$/ ) {
                $cursor++;
            }
            my @ids;
            my $id_cursor = $cursor;
            while ( $id_cursor < @lines && $lines[$id_cursor] =~ /^\s*(\d+)\s*,?\s*$/ ) {
                push @ids, $1;
                $id_cursor++;
            }
            if (@ids) {
                push @out, "$key: " . join( ',', @ids );
                $i = $id_cursor;
                next LINE;
            }
        }
        push @out, $line;
        $i++;
    }

    return join "\n", @out;
}

=head3 build_minimal_payload

Builds a minimal payload with just IDs and notice type.

=cut

sub build_minimal_payload {
    my ($self, $data, $yaml) = @_;

    my $payload = {
        notice_type    => $data->{message}->{letter_code},
        transport_type => $data->{message}->{message_transport_type},
        message_id     => $data->{message}->{message_id},
    };

    # Add relevant IDs based on what's available
    $payload->{patron_id}  = $data->{patron}->{borrowernumber} if $data->{patron};
    $payload->{library_id} = $data->{library}->{branchcode}    if $data->{library};

    # Add hold ID if present
    if ($data->{holds} && @{$data->{holds}}) {
        if (scalar @{$data->{holds}} == 1) {
            $payload->{hold_id} = $data->{holds}->[0]->{hold}->{reserve_id};
        } else {
            $payload->{hold_ids} = [map { $_->{hold}->{reserve_id} } @{$data->{holds}}];
        }
    }

    # Add checkout ID if present
    if ($data->{checkouts} && @{$data->{checkouts}}) {
        if (scalar @{$data->{checkouts}} == 1) {
            $payload->{checkout_id} = $data->{checkouts}->[0]->{checkout}->{issue_id};
        } else {
            $payload->{checkout_ids} = [map { $_->{checkout}->{issue_id} } @{$data->{checkouts}}];
        }
    }

    # Add item ID if present
    $payload->{item_id}   = $data->{item}->{itemnumber}   if $data->{item};
    $payload->{biblio_id} = $data->{biblio}->{biblionumber} if $data->{biblio};

    return $payload;
}

sub scrub_biblio {
    my ($self, $biblio) = @_;

    delete $biblio->{abstract};

    return $biblio;
}

sub scrub_patron {
    my ($self, $patron) = @_;

    delete $patron->{password};
    delete $patron->{borrowernotes};

    return $patron;
}

sub scrub_message {
    my ($self, $message) = @_;

    delete $message->{content};
    delete $message->{metadata};

    return $message;
}

sub api_routes {
    my ($self, $args) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

=head3 encrypt_credentials

Encrypts OAuth2 credentials using AES-256 encryption and stores them as a base64-encoded JSON string.

=cut

sub encrypt_credentials {
    my ($self, $credentials) = @_;

    my $json = encode_json($credentials);

    # Use Koha::Encryption for AES-256 encryption
    require Koha::Encryption;
    my $cipher = Koha::Encryption->new;

    my $encrypted = $cipher->encrypt_hex($json);

    return $encrypted;
}

=head3 decrypt_credentials

Decrypts encrypted OAuth2 credentials and returns them as a hashref.

=cut

sub decrypt_credentials {
    my ($self, $encrypted_string) = @_;

    require Koha::Encryption;
    my $cipher = Koha::Encryption->new;

    my $decrypted = $cipher->decrypt_hex($encrypted_string);
    my $credentials = decode_json($decrypted);

    return $credentials;
}

=head3 get_oauth_credentials

Retrieves OAuth2 credentials with fallback from system preference to koha-conf.xml.

Returns undef if credentials are not configured.

=cut

sub get_oauth_credentials {
    my ($self) = @_;

    # Return cached credentials if available
    return $oauth_credentials_cache if $oauth_credentials_cache;

    # Try encrypted system preference first
    my $encrypted = C4::Context->preference('WebhookCredentials');
    if ($encrypted) {
        $oauth_credentials_cache = $self->decrypt_credentials($encrypted);
        return $oauth_credentials_cache;
    }

    # Fallback to koha-conf.xml (plain text)
    my $auth_url      = C4::Context->config('webhook_auth_url');
    my $client_id     = C4::Context->config('webhook_client_id');
    my $client_secret = C4::Context->config('webhook_client_secret');
    my $notice_url    = C4::Context->config('webhook_notice_url');
    my $customer_id   = C4::Context->config('webhook_customer_id');

    if ($auth_url && $client_id && $client_secret && $notice_url) {
        $oauth_credentials_cache = {
            auth_url      => $auth_url,
            client_id     => $client_id,
            client_secret => $client_secret,
            notice_url    => $notice_url,
            customer_id   => $customer_id,
        };
        return $oauth_credentials_cache;
    }

    return;
}

=head3 has_oauth_credentials

Checks if OAuth2 credentials are configured either in system preference or koha-conf.xml.

=cut

sub has_oauth_credentials {
    my ($self) = @_;

    return 1 if C4::Context->preference('WebhookCredentials');
    return 1 if (C4::Context->config('webhook_auth_url') &&
                 C4::Context->config('webhook_client_id') &&
                 C4::Context->config('webhook_client_secret') &&
                 C4::Context->config('webhook_notice_url'));
    return 0;
}

=head3 get_display_auth_url

Returns the display value for the auth URL, checking system preference first then koha-conf.xml.

=cut

sub get_display_auth_url {
    my ($self) = @_;
    my $syspref = $self->get_decrypted_syspref('WebhookCredentials');
    return $syspref->{auth_url} if $syspref;
    return C4::Context->config('webhook_auth_url') // '';
}

=head3 get_display_client_id

Returns the display value for the client ID, checking system preference first then koha-conf.xml.

=cut

sub get_display_client_id {
    my ($self) = @_;
    my $syspref = $self->get_decrypted_syspref('WebhookCredentials');
    return $syspref->{client_id} if $syspref;
    return C4::Context->config('webhook_client_id') // '';
}

=head3 get_display_notice_url

Returns the display value for the notice URL, checking system preference first then koha-conf.xml.

=cut

sub get_display_notice_url {
    my ($self) = @_;
    my $syspref = $self->get_decrypted_syspref('WebhookCredentials');
    return $syspref->{notice_url} if $syspref;
    return C4::Context->config('webhook_notice_url') // '';
}

=head3 get_display_customer_id

Returns the display value for the customer ID, checking system preference first then koha-conf.xml.

=cut

sub get_display_customer_id {
    my ($self) = @_;
    my $syspref = $self->get_decrypted_syspref('WebhookCredentials');
    return $syspref->{customer_id} // '' if $syspref;
    return C4::Context->config('webhook_customer_id') // '';
}

=head3 get_decrypted_syspref

Retrieves and decrypts webhook credentials from system preference.

=cut

sub get_decrypted_syspref {
    my ($self, $preference_name) = @_;

    my $syspref = C4::Context->preference($preference_name);
    if ( $syspref ) {
        return $self->decrypt_credentials($syspref);
    }
}

=head3 set_encrypted_syspref

Encrypts and stores OAuth2 credentials as a system preference.

=cut

sub set_encrypted_syspref {
    my ($self, $preference_name, $credentials) = @_;

    my $encrypted = $self->encrypt_credentials($credentials);

    C4::Context->set_preference($preference_name, $encrypted);

    # Invalidate cache to ensure next credential retrieval fetches new values
    $oauth_credentials_cache = undef;
}

=head3 invalidate_oauth_credentials_cache

Explicitly invalidates the OAuth2 credentials cache. Useful when credentials
have been updated via admin interface.

=cut

sub invalidate_oauth_credentials_cache {
    my ($self) = @_;
    $oauth_credentials_cache = undef;
}

sub api_namespace {
    my ($self) = @_;

    return 'webhook_notifications';
}

1;
