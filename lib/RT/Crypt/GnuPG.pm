package RT::Crypt::GnuPG;

use strict;
use warnings;

use IO::Handle;
use GnuPG::Interface;
use RT::EmailParser ();

# gnupg options supported by GnuPG::Interface
# other otions should be handled via extra_args argument
my %supported_opt = map { $_ => 1 } qw(
       always_trust
       armor
       batch
       comment
       compress_algo
       default_key
       encrypt_to
       extra_args
       force_v3_sigs
       homedir
       logger_fd
       no_greeting
       no_options
       no_verbose
       openpgp
       options
       passphrase_fd
       quiet
       recipients
       rfc1991
       status_fd
       textmode
       verbose
);

=head2 SignEncrypt Entity => MIME::Entity, [ Encrypt => 1, Sign => 1, Passphrase => undef ]

Signs and/or encrypts an email message with GnuPG utility. A passphrase is required
only during signing, if value is undefined then L</GetPassphrase> called to get it.

Returns a hash with the following keys:

* exit_code
* error
* logger
* status
* message

=cut

sub _safe_run_child (&) {
    # We need to reopen stdout temporarily, because in FCGI
    # environment, stdout is tied to FCGI::Stream, and the child
    # of the run3 wouldn't be able to reopen STDOUT properly.
    my $stdin = IO::Handle->new;
    $stdin->fdopen( 0, 'r' );
    local *STDIN = $stdin;

    my $stdout = IO::Handle->new;
    $stdout->fdopen( 1, 'w' );
    local *STDOUT = $stdout;

    my $stderr = IO::Handle->new;
    $stderr->fdopen( 2, 'w' );
    local *STDERR = $stderr;

    local $SIG{'CHLD'} = 'DEFAULT';
    local @ENV{'LANG', 'LC_ALL'} = ('C', 'C');
    shift->();
}

sub SignEncrypt {
    
    my $format = lc RT->Config->Get('GnuPG')->{'OutgoingMessagesFormat'} || 'RFC';
    if ( $format eq 'inline' ) {
        SignEncryptInline( @_ );
    } else {
        SignEncryptRFC3156( @_ );
    }
}

sub SignEncryptRFC3156 {
    my %args = (
        Entity => undef,
        Encrypt => 1,
        Sign => 1,
        Passphrase => undef,
        @_
    );
    my $entity = $args{'Entity'};

    if ( $args{'Sign'} && !defined $args{'Passphrase'} ) {
        $args{'Passphrase'} = GetPassphrase();
    }

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    # address of the queue
    my $sign_as = (Mail::Address->parse( $entity->head->get( 'From' ) ))[0]->address;
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        armor => 1,
        meta_interactive => 0,
        default_key => $sign_as,
    );

    my %res;
    if ( $args{'Sign'} && !$args{'Encrypt'} ) {
        # required by RFC3156(Ch. 5) and RFC1847(Ch. 2.1)
        $entity->head->mime_attr('Content-Transfer-Encoding' => 'quoted-printable');

        my %handle;
        my $handles = GnuPG::Handles->new(
            stdin  => ($handle{'input'}  = new IO::Handle::CRLF),
            stdout => ($handle{'output'} = new IO::Handle),
            stderr => ($handle{'error'}  = new IO::Handle),
            logger => ($handle{'logger'} = new IO::Handle),
            status => ($handle{'status'} = new IO::Handle),
        );
        $gnupg->passphrase( $args{'Passphrase'} );

        eval {
            my $pid = _safe_run_child { $gnupg->detach_sign( handles => $handles ) };
            $entity->make_multipart( 'mixed', Force => 1 );
            $entity->parts(0)->print( $handle{'input'} );
            close $handle{'input'};
            waitpid $pid, 0;
        };
	my $err = $@;
        my @signature = readline $handle{'output'};
        close $handle{'output'};

        $res{'exit_code'} = $?;
        foreach ( qw(error logger status) ) {
            $res{$_} = do { local $/; readline $handle{$_} };
            delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
            close $handle{$_};
        }
        $RT::Logger->debug( $res{'status'} ) if $res{'status'};
        $RT::Logger->warning( $res{'error'} ) if $res{'error'};
        $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
        if ( $err || $res{'exit_code'} ) {
            $res{'message'} = $err? $err : "gpg exitted with error code ". ($res{'exit_code'} >> 8);
            return %res;
        }

        # setup RFC1847(Ch.2.1) requirements
        my $protocol = 'application/pgp-signature';
        $entity->head->mime_attr( 'Content-Type' => 'multipart/signed' );
        $entity->head->mime_attr( 'Content-Type.protocol' => $protocol );
        $entity->head->mime_attr( 'Content-Type.micalg'   => 'pgp-'. lc $opt{'digest-algo'} );
        $entity->attach(
            Type        => $protocol,
            Disposition => 'inline',
            Data        => \@signature,
            Encoding    => '7bit',
        );
    }
    if ( $args{'Encrypt'} ) {
        my %seen;
        $gnupg->options->push_recipients( $_ )
            foreach grep !$seen{ $_ }++, map $_->address,
            map Mail::Address->parse( $entity->head->get( $_ ) ),
            qw(To Cc Bcc);

        my ($tmp_fh, $tmp_fn) = File::Temp::tempfile();
        binmode $tmp_fh, ':raw';

        my %handle;
        my $handles = GnuPG::Handles->new(
            stdin  => ($handle{'input'}  = new IO::Handle),
            stdout => $tmp_fh,
            stderr => ($handle{'error'}  = new IO::Handle),
            logger => ($handle{'logger'} = new IO::Handle),
            status => ($handle{'status'} = new IO::Handle),
        );
        $handles->options( 'stdout'  )->{'direct'} = 1;
        $gnupg->passphrase( $args{'Passphrase'} ) if $args{'Sign'};

        eval {
            my $pid = _safe_run_child { $args{'Sign'}
                ? $gnupg->sign_and_encrypt( handles => $handles )
                : $gnupg->encrypt( handles => $handles ) };
            $entity->make_multipart( 'mixed', Force => 1 );
            $entity->parts(0)->print( $handle{'input'} );
            close $handle{'input'};
            waitpid $pid, 0;
        };

        $res{'exit_code'} = $?;
        foreach ( qw(error logger status) ) {
            $res{$_} = do { local $/; readline $handle{$_} };
            delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
            close $handle{$_};
        }
        $RT::Logger->debug( $res{'status'} ) if $res{'status'};
        $RT::Logger->warning( $res{'error'} ) if $res{'error'};
        $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
        if ( $@ || $? ) {
            $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
            return %res;
        }

        my $protocol = 'application/pgp-encrypted';
        $entity->parts([]);
        $entity->head->mime_attr( 'Content-Type' => 'multipart/encrypted' );
        $entity->head->mime_attr( 'Content-Type.protocol' => $protocol );
        $entity->attach(
            Type        => $protocol,
            Disposition => 'inline',
            Data        => ['Version: 1',''],
            Encoding    => '7bit',
        );
        $entity->attach(
            Type        => 'application/octet-stream',
            Disposition => 'inline',
            Path        => $tmp_fn,
            Filename    => '',
            Encoding    => '7bit',
        );
        $entity->parts(-1)->bodyhandle->{'_dirty_hack_to_save_a_ref_tmp_fh'} = $tmp_fh;
    }
    %res;
}

sub FindProtectedParts {
    my %args = ( Entity => undef, CheckBody => 1, @_ );
    my $entity = $args{'Entity'};

    # inline PGP block, only in singlepart
    unless ( $entity->is_multipart ) {
        my $io = $entity->open('r');
        while ( defined($_ = $io->getline) ) {
            next unless /-----BEGIN PGP (SIGNED )?MESSAGE-----/;
            return {
                Type   => ( $1? 'signed': 'encrypted' ),
                Format => 'Inline',
                Data   => $entity,
            };
        }
        $io->close;
        return ();
    }

    # RFC3156, multipart/{signed,encrypted}
    if ( ( my $type = $entity->effective_type ) =~ /^multipart\/(?:encrypted|signed)$/ ) {
        unless ( $entity->parts == 2 ) {
            $RT::Logger->error( "Encrypted or signed entity must has two subparts. Skipped" );
            return ();
        }

        my $protocol = $entity->head->mime_attr( 'Content-Type.protocol' );
        unless ( $protocol ) {
            $RT::Logger->error( "Entity is '$type', but has no protocol defined. Skipped" );
            return ();
        }

        if ( $type eq 'multipart/encrypted' ) {
            unless ( $protocol eq 'application/pgp-encrypted' ) {
                $RT::Logger->info( "Skipping protocol '$protocol', only 'application/pgp-encrypted' is supported" );
                return ();
            }
            return {
                Type   => 'encrypted',
                Format => 'RFC3156',
                Top    => $entity,
                Data   => $entity->parts(1),
                Info   => $entity->parts(0),
            };
        } else {
            unless ( $protocol eq 'application/pgp-signature' ) {
                $RT::Logger->info( "Skipping protocol '$protocol', only 'application/pgp-signature' is supported" );
                return ();
            }
            return {
                Type      => 'signed',
                Format    => 'RFC3156',
                Top       => $entity,
                Data      => $entity->parts(0),
                Signature => $entity->parts(1),
            };
        }
    }

    # attachments signed with signature in another part
    my @file_signatures =
        grep $_->head->recommended_filename,
        grep $_->effective_type eq 'application/pgp-signature',
        $entity->parts;

    my (@res, %skip);
    foreach my $sig_part ( @file_signatures ) {
        $skip{"$sig_part"}++;
        my $sig_name = $sig_part->head->recommended_filename;
        my ($file_name) = $sig_name =~ /^(.*?)(?:.sig)?$/;
        my ($data_part) =
            grep $file_name eq ($_->head->recommended_filename||''),
            grep $_ ne $sig_part,
            $entity->parts;
        unless ( $data_part ) {
            $RT::Logger->error("Found $sig_name attachment, but didn't find $file_name");
            next;
        }

        $skip{"$data_part"}++;
        push @res, {
            Type      => 'signed',
            Format    => 'Attachment',
            Top       => $entity,
            Data      => $data_part,
            Signature => $sig_part,
        };
    }

    # attachments with inline encryption
    my @encrypted_files =
        grep $_->head->recommended_filename
            && $_->head->recommended_filename =~ /\.pgp$/,
        $entity->parts;

    foreach my $part ( @encrypted_files ) {
        $skip{"$part"}++;
        push @res, {
            Type      => 'encrypted',
            Format    => 'Attachment',
            Top       => $entity,
            Data      => $part,
        };
    }

    push @res, FindProtectedParts( Entity => $_ )
        foreach grep !$skip{"$_"}, $entity->parts;

    return @res;
}

=head2 VerifyDecrypt Entity => undef, [ Detach => 1, Passphrase => undef ]

=cut

sub VerifyDecrypt {
    my %args = ( Entity => undef, Detach => 1, @_ );
    my @protected = FindProtectedParts( Entity => $args{'Entity'} );
    my @res;
    # XXX: detaching may brake nested signatures
    foreach my $item( grep $_->{'Type'} eq 'signed', @protected ) {
        if ( $item->{'Format'} eq 'RFC3156' ) {
            push @res, { VerifyRFC3156( %$item ) };
            if ( $args{'Detach'} ) {
                $item->{'Top'}->parts( [ $item->{'Data'} ] );
                $item->{'Top'}->make_singlepart;
            }
        } elsif ( $item->{'Format'} eq 'Inline' ) {
            push @res, { VerifyInline( %$item ) };
        } elsif ( $item->{'Format'} eq 'Attachment' ) {
            push @res, { VerifyAttachment( %$item ) };
            if ( $args{'Detach'} ) {
                $item->{'Top'}->parts( [ grep "$_" ne $item->{'Signature'}, $item->{'Top'}->parts ] );
                $item->{'Top'}->make_singlepart;
            }
        }
    }
    foreach my $item( grep $_->{'Type'} eq 'encrypted', @protected ) {
        if ( $item->{'Format'} eq 'RFC3156' ) {
            push @res, { DecryptRFC3156( %$item ) };
        } elsif ( $item->{'Format'} eq 'Inline' ) {
            push @res, { DecryptInline( %$item ) };
        } elsif ( $item->{'Format'} eq 'Attachment' ) {
            push @res, { DecryptAttachment( %$item ) };
#            if ( $args{'Detach'} ) {
#                $item->{'Top'}->parts( [ grep "$_" ne $item->{'Signature'}, $item->{'Top'}->parts ] );
#                $item->{'Top'}->make_singlepart;
#            }
        }
    }
    return @res;
}

sub VerifyInline {
    my %args = ( Data => undef, Top => undef, @_ );

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    my %handle;
    my $handles = GnuPG::Handles->new(
        stdin  => ($handle{'input'}  = new IO::Handle),
        stdout => ($handle{'output'} = new IO::Handle),
        stderr => ($handle{'error'}  = new IO::Handle),
        logger => ($handle{'logger'} = new IO::Handle),
        status => ($handle{'status'} = new IO::Handle),
    );

    my %res;
    eval {
        my $pid = _safe_run_child { $gnupg->verify( handles => $handles ) };
        $args{'Data'}->bodyhandle->print( $handle{'input'} );
        close $handle{'input'};

        waitpid $pid, 0;
    };
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $@ || $? ) {
        $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
    }
    return %res;
}

sub VerifyAttachment {
    my %args = ( Data => undef, Signature => undef, Top => undef, @_ );

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    my ($tmp_fh, $tmp_fn) = File::Temp::tempfile();
    binmode $tmp_fh, ':raw';
    $args{'Data'}->bodyhandle->print( $tmp_fh );
    $tmp_fh->flush;

    my %handle;
    my $handles = GnuPG::Handles->new(
        stdin  => ($handle{'input'}  = new IO::Handle),
        stdout => ($handle{'output'} = new IO::Handle),
        stderr => ($handle{'error'}  = new IO::Handle),
        logger => ($handle{'logger'} = new IO::Handle),
        status => ($handle{'status'} = new IO::Handle),
    );

    my %res;
    eval {
        my $pid = _safe_run_child { $gnupg->verify( handles => $handles, command_args => [ '-', $tmp_fn ] ) };
        $args{'Signature'}->bodyhandle->print( $handle{'input'} );
        close $handle{'input'};

        waitpid $pid, 0;
    };
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $@ || $? ) {
        $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
    }
    return %res;
}

sub VerifyRFC3156 {
    my %args = ( Data => undef, Signature => undef, Top => undef, @_ );

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    my ($tmp_fh, $tmp_fn) = File::Temp::tempfile();
    binmode $tmp_fh, ':raw:eol(CRLF?)';
    $args{'Data'}->print( $tmp_fh );
    $tmp_fh->flush;

    my %handle;
    my $handles = GnuPG::Handles->new(
        stdin  => ($handle{'input'}  = new IO::Handle),
        stdout => ($handle{'output'} = new IO::Handle),
        stderr => ($handle{'error'}  = new IO::Handle),
        logger => ($handle{'logger'} = new IO::Handle),
        status => ($handle{'status'} = new IO::Handle),
    );

    my %res;
    eval {
        my $pid = _safe_run_child { $gnupg->verify( handles => $handles, command_args => [ '-', $tmp_fn ] ) };
        $args{'Signature'}->bodyhandle->print( $handle{'input'} );
        close $handle{'input'};

        waitpid $pid, 0;
    };
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $@ || $? ) {
        $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
    }
    return %res;
}

sub DecryptRFC3156 {
    my %args = (
        Data => undef,
        Info => undef,
        Top => undef,
        Passphrase => undef,
        @_
    );

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    $args{'Passphrase'} = GetPassphrase()
        unless defined $args{'Passphrase'};

    my ($tmp_fh, $tmp_fn) = File::Temp::tempfile();
    binmode $tmp_fh, ':raw';

    my %handle;
    my $handles = GnuPG::Handles->new(
        stdin  => ($handle{'input'}  = new IO::Handle),
        stdout => $tmp_fh,
        stderr => ($handle{'error'}  = new IO::Handle),
        logger => ($handle{'logger'} = new IO::Handle),
        status => ($handle{'status'} = new IO::Handle),
    );
    $handles->options( 'stdout' )->{'direct'} = 1;

    my %res;
    eval {
        $gnupg->passphrase( $args{'Passphrase'} );
        my $pid = _safe_run_child { $gnupg->decrypt( handles => $handles ) };
        $args{'Data'}->bodyhandle->print( $handle{'input'} );
        close $handle{'input'};

        waitpid $pid, 0;
    };
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $@ || $? ) {
        $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
        return %res;
    }

    seek $tmp_fh, 0, 0;
    my $parser = new MIME::Parser;
    my $rt_parser = new RT::EmailParser;
    $rt_parser->_SetupMIMEParser( $parser );
    my $decrypted = $parser->parse( $tmp_fh );
    $decrypted->{'__store_link_to_object_to_avoid_early_cleanup'} = $rt_parser;
    $args{'Top'}->parts( [] );
    $args{'Top'}->add_part( $decrypted );
    $args{'Top'}->make_singlepart;
    return %res;
}

sub DecryptInline {
    my %args = (
        Data => undef,
        Passphrase => undef,
        @_
    );

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    $args{'Passphrase'} = GetPassphrase()
        unless defined $args{'Passphrase'};

    my ($tmp_fh, $tmp_fn) = File::Temp::tempfile();
    binmode $tmp_fh, ':raw';

    my %handle;
    my $handles = GnuPG::Handles->new(
        stdin  => ($handle{'input'}  = new IO::Handle),
        stdout => $tmp_fh,
        stderr => ($handle{'error'}  = new IO::Handle),
        logger => ($handle{'logger'} = new IO::Handle),
        status => ($handle{'status'} = new IO::Handle),
    );
    $handles->options( 'stdout' )->{'direct'} = 1;

    my %res;
    eval {
        $gnupg->passphrase( $args{'Passphrase'} );
        my $pid = _safe_run_child { $gnupg->decrypt( handles => $handles ) };
        $args{'Data'}->bodyhandle->print( $handle{'input'} );
        close $handle{'input'};

        waitpid $pid, 0;
    };
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $@ || $? ) {
        $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
        return %res;
    }

    seek $tmp_fh, 0, 0;
    $args{'Data'}->bodyhandle( new MIME::Body::File $tmp_fn );
    $args{'Data'}->{'__store_tmp_handle_to_avoid_early_cleanup'} = $tmp_fh;
    return %res;
}

sub DecryptAttachment {
    my %args = (
        Top  => undef,
        Data => undef,
        Passphrase => undef,
        @_
    );
    my %res = DecryptInline( %args );
    return %res if $res{'exit_code'};

    my $filename = $args{'Data'}->head->recommended_filename;
    $filename =~ s/\.pgp$//i;
    $args{'Data'}->head->mime_attr( $_ => $filename )
        foreach (qw(Content-Type.name Content-Disposition.filename));

    return %res;
}

sub GetPassphrase {
    return 'passphrase';
}

=head2 ParseStatus

Takes a string containing output of gnupg status stream. Parses it and returns
array of hashes. Each element of array is a hash ref and represents line or
group of lines in the status message.

All hashes have Operation, Status and Message elements.

=over

=item Operation

Classification of operations gnupg perfoms. Now we have suppoort
for Sign, Encrypt, Decrypt, Verify, PassphraseCheck, RecipientsCheck and Data
values.

=item Status

Informs about success. Value is 'DONE' on success, other values means that
an operation failed, for example 'ERROR', 'BAD', 'MISSING' and may be other.

=item Message

User friendly message.

=back

This parser is based on information from GnuPG distribution, see also
F<docs/design_docs/gnupg_details_on_output_formats> in the RT distribution.

=cut

my %REASON_CODE_TO_TEXT = (
    NODATA => {
        1 => "No armored data",
        2 => "Expected a packet, but did not found one",
        3 => "Invalid packet found",
        4 => "Signature expected, but not found",
    },
    INV_RECP => {
        0 => "No specific reason given",
        1 => "Not Found",
        2 => "Ambigious specification",
        3 => "Wrong key usage",
        4 => "Key revoked",
        5 => "Key expired",
        6 => "No CRL known",
        7 => "CRL too old",
        8 => "Policy mismatch",
        9 => "Not a secret key",
        10 => "Key not trusted",
    },
    ERRSIG => {
        0 => 'not specified',
        4 => 'unknown algorithm',
        9 => 'missing public key',
    },
);

sub ReasonCodeToText {
    my $keyword = shift;
    my $code = shift;
    return $REASON_CODE_TO_TEXT{ $keyword }{ $code }
        if exists $REASON_CODE_TO_TEXT{ $keyword }{ $code };
    return 'unknown';
}

my %simple_keyword = (
    NO_RECP => {
        Operation => 'RecipientsCheck',
        Status    => 'ERROR',
        Message   => 'No recipients',
    },
    UNEXPECTED => {
        Operation => 'Data',
        Status    => 'ERROR',
        Message   => 'Unexpected data has been encountered',
    },
    BADARMOR => {
        Operation => 'Data',
        Status    => 'ERROR',
        Message   => 'The ASCII armor is corrupted',
    },
);

# keywords we parse
my %parse_keyword = map { $_ => 1 } qw(
    USERID_HINT
    SIG_CREATED GOODSIG
    END_ENCRYPTION
    DECRYPTION_FAILED DECRYPTION_OKAY
    BAD_PASSPHRASE GOOD_PASSPHRASE
    ENC_TO
    NO_SECKEY NO_PUBKEY
    NO_RECP INV_RECP NODATA UNEXPECTED
);

# keywords we ignore without any messages as we parse them using other
# keywords as starting point or just ignore as they are useless for us
my %ignore_keyword = map { $_ => 1 } qw(
    NEED_PASSPHRASE MISSING_PASSPHRASE BEGIN_SIGNING PLAINTEXT PLAINTEXT_LENGTH
    BEGIN_ENCRYPTION SIG_ID VALIDSIG
    BEGIN_DECRYPTION END_DECRYPTION GOODMDC
    TRUST_UNDEFINED TRUST_NEVER TRUST_MARGINAL TRUST_FULLY TRUST_ULTIMATE
);

sub ParseStatus {
    my $status = shift;
    return () unless $status;

    my @status;
    while ( $status =~ /\[GNUPG:\]\s*(.*?)(?=\[GNUPG:\]|\z)/igms ) {
        push @status, $1; $status[-1] =~ s/\s+/ /g; $status[-1] =~ s/\s+$//;
    }
    $status = join "\n", @status;
    study $status;

    my @res;
    my (%user_hint, $latest_user_main_key);
    for ( my $i = 0; $i < @status; $i++ ) {
        my $line = $status[$i];
        my ($keyword, $args) = ($line =~ /^(\S+)\s*(.*)$/s);
        if ( $simple_keyword{ $keyword } ) {
            push @res, $simple_keyword{ $keyword };
            $res[-1]->{'Keyword'} = $keyword;
            next;
        }
        unless ( $parse_keyword{ $keyword } ) {
            $RT::Logger->warning("Skipped $keyword") unless $ignore_keyword{ $keyword };
            next;
        }

        if ( $keyword eq 'USERID_HINT' ) {
            my %tmp = _ParseUserHint($status, $line);
            $latest_user_main_key = $tmp{'MainKey'};
            if ( $user_hint{ $tmp{'MainKey'} } ) {
                while ( my ($k, $v) = each %tmp ) {
                    $user_hint{ $tmp{'MainKey'} }->{$k} = $v;
                }
            } else {
                $user_hint{ $tmp{'MainKey'} } = \%tmp;
            }
        }
        elsif ( $keyword eq 'BAD_PASSPHRASE' || $keyword eq 'GOOD_PASSPHRASE' ) {
            my $key_id = $args;
            my %res = (
                Operation => 'PassphraseCheck',
                Status    => $keyword eq 'BAD_PASSPHRASE'? 'BAD' : 'DONE',
                Key       => $key_id,
            );
            $res{'Status'} = 'MISSING' if $status[ $i - 1 ] =~ /^MISSING_PASSPHRASE/;
            foreach my $line ( reverse @status[ 0 .. $i-1 ] ) {
                next unless $line =~ /^NEED_PASSPHRASE\s+(\S+)\s+(\S+)\s+(\S+)/;
                next if $key_id && $2 ne $key_id;
                @res{'MainKey', 'Key', 'KeyType'} = ($1, $2, $3);
                last;
            }
            $res{'Message'} = ucfirst( lc( $res{'Status'} eq 'DONE'? 'GOOD': $res{'Status'} ) ) .' passphrase';
            $res{'User'} = ( $user_hint{ $res{'MainKey'} } ||= {} ) if $res{'MainKey'};
            if ( exists $res{'User'}->{'EmailAddress'} ) {
                $res{'Message'} .= ' for '. $res{'User'}->{'EmailAddress'};
            } else {
                $res{'Message'} .= " for '0x$key_id'";
            }
            push @res, \%res;
        }
        elsif ( $keyword eq 'END_ENCRYPTION' ) {
            my %res = (
                Operation => 'Encrypt',
                Status    => 'DONE',
                Message   => 'Data has been encrypted',
            );
            foreach my $line ( reverse @status[ 0 .. $i-1 ] ) {
                next unless $line =~ /^BEGIN_ENCRYPTION\s+(\S+)\s+(\S+)/;
                @res{'MdcMethod', 'SymAlgo'} = ($1, $2);
                last;
            }
            push @res, \%res;
        }
        elsif ( $keyword eq 'DECRYPTION_FAILED' ) {
            my %res = (
                Operation => 'Decrypt',
                Status    => 'ERROR',
                Message   => 'Decryption failed',
            );
            push @res, \%res;
        }
        elsif ( $keyword eq 'DECRYPTION_OKAY' ) {
            my %res = (
                Operation => 'Decrypt',
                Status    => 'DONE',
                Message   => 'Decryption process succeeded',
            );
            push @res, \%res;
        }
        elsif ( $keyword eq 'ENC_TO' ) {
            my ($key, $alg, $key_length) = split /\s+/, $args;
            my %res = (
                Operation => 'Decrypt',
                Status    => 'DONE',
                Message   => "The message is encrypted to '0x$key'",
                Key       => $key,
                KeyLength => $key_length,
                Algorithm => $alg,
            );
            $res{'User'} = ( $user_hint{ $key } ||= {} );
            push @res, \%res;
        }
        elsif ( $keyword eq 'NO_SECKEY' || $keyword eq 'NO_PUBKEY' ) {
            my ($key) = split /\s+/, $args;
            my $type = $keyword eq 'NO_SECKEY'? 'secret': 'public';
            my %res = (
                Operation => 'KeyCheck',
                Status    => 'MISSING',
                Message   => ucfirst( $type ) ." key '0x$key' is not available",
                Key       => $key,
            );
            $res{'User'} = ( $user_hint{ $key } ||= {} );
            push @res, \%res;
        }
        # GOODSIG, BADSIG, VALIDSIG, TRUST_*
        elsif ( $keyword eq 'GOODSIG' ) {
            my %res = (
                Operation  => 'Verify',
                Status     => 'DONE',
                Message    => 'The signature is good',
            );
            @res{qw(Key UserString)} = split /\s+/, $args, 2;
            $res{'Message'} .= ', signed by '. $res{'UserString'};

            foreach my $line ( @status[ $i .. $#status ] ) {
                next unless $line =~ /^TRUST_(\S+)/;
                $res{'Trust'} = $1;
                last;
            }
            $res{'Message'} .= ', trust level is '. lc( $res{'Trust'} || 'unknown');

            foreach my $line ( @status[ $i .. $#status ] ) {
                next unless $line =~ /^VALIDSIG\s+(.*)/;
                @res{ qw(
                    Fingerprint
                    CreationDate
                    Timestamp
                    ExpireTimestamp
                    Version
                    Reserved
                    PubkeyAlgo
                    HashAlgo
                    Class
                    PKFingerprint
                    Other
                ) } = split /\s+/, $1, 10;
                last;
            }
            push @res, \%res;
        }
        elsif ( $keyword eq 'BADSIG' ) {
            my %res = (
                Operation  => 'Verify',
                Status     => 'BAD',
                Message    => 'The signature has not been verified okay',
            );
            @res{qw(Key UserString)} = split /\s+/, $args, 2;
            push @res, \%res;
        }
        elsif ( $keyword eq 'ERRSIG' ) {
            my %res = (
                Operation => 'Verify',
                Status    => 'ERROR',
                Message   => 'Not possible to check the signature',
            );
            @res{qw(Key PubkeyAlgo HashAlgo Class Timestamp ReasonCode Other)}
                = split /\s+/, $args, 7;

            $res{'Reason'} = ReasonCodeToText( $keyword, $res{'ReasonCode'} );
            $res{'Message'} .= ", the reasion is ". $res{'Reason'};

            push @res, \%res;
        }
        elsif ( $keyword eq 'SIG_CREATED' ) {
            # SIG_CREATED <type> <pubkey algo> <hash algo> <class> <timestamp> <key fpr>
            my @props = split /\s+/, $args;
            push @res, {
                Operation      => 'Sign',
                Status         => 'DONE',
                Message        => "Signed message",
                Type           => $props[0],
                PubKeyAlgo     => $props[1],
                HashKeyAlgo    => $props[2],
                Class          => $props[3],
                Timestamp      => $props[4],
                KeyFingerprint => $props[5],
                User           => $user_hint{ $latest_user_main_key },
            };
            $res[-1]->{Message} .= ' by '. $user_hint{ $latest_user_main_key }->{'EmailAddress'}
                if $user_hint{ $latest_user_main_key };
        }
        elsif ( $keyword eq 'INV_RECP' ) {
            my ($rcode, $recipient) = split /\s+/, $args, 2;
            my $reason = ReasonCodeToText( $keyword, $rcode );
            push @res, {
                Operation  => 'RecipientsCheck',
                Status     => 'ERROR',
                Message    => "Recipient '$recipient' is unusable, the reason is '$reason'",
                Recipient  => $recipient,
                ReasonCode => $rcode,
                Reason     => $reason,
            };
        }
        elsif ( $keyword eq 'NODATA' ) {
            my $rcode = (split /\s+/, $args)[0];
            my $reason = ReasonCodeToText( $keyword, $rcode );
            push @res, {
                Operation  => 'Data',
                Message    => "No data has been found. The reason is '$reason'",
                ReasonCode => $rcode,
                Reason     => $reason,
            };
        }
        else {
            $RT::Logger->warning("Keyword $keyword is unknown");
            next;
        }
        $res[-1]{'Keyword'} = $keyword unless $res[-1]{'Keyword'};
    }
    return @res;
}

sub _ParseUserHint {
    my ($status, $hint) = (@_);
    my ($main_key_id, $user_str) = ($hint =~ /^USERID_HINT\s+(\S+)\s+(.*)$/);
    return () unless $main_key_id;
    return (
        MainKey      => $main_key_id,
        String       => $user_str,
        EmailAddress => (map $_->address, Mail::Address->parse( $user_str ))[0],
    );
}

sub _PrepareGnuPGOptions {
    my %opt = @_;
    my %res = map { lc $_ => $opt{ $_ } } grep $supported_opt{ lc $_ }, keys %opt;
    $res{'extra_args'} ||= [];
    foreach my $o ( grep !$supported_opt{ lc $_ }, keys %opt ) {
        push @{ $res{'extra_args'} }, '--'. lc $o;
        push @{ $res{'extra_args'} }, $opt{ $o }
            if defined $opt{ $o };
    }
    return %res;
}

sub GetPublicKeyInfo {
    return GetKeyInfo(shift, 'public');
}

sub GetPrivateKeyInfo {
    return GetKeyInfo(shift, 'private');
}

sub GetKeyInfo {
    my $email = shift;
    my $type = shift || 'public';

    my $gnupg = new GnuPG::Interface;
    my %opt = RT->Config->Get('GnuPGOptions');
    $opt{'digest-algo'} ||= 'SHA1';
    $opt{'with-colons'} = undef; # parseable format
    $opt{'fixed-list-mode'} = undef; # don't merge uid with keys
    $gnupg->options->hash_init(
        _PrepareGnuPGOptions( %opt ),
        armor => 1,
        meta_interactive => 0,
    );

    my %res;

    my %handle;
    my $handles = GnuPG::Handles->new(
        stdout => ($handle{'output'} = new IO::Handle),
        stderr => ($handle{'error'}  = new IO::Handle),
        logger => ($handle{'logger'} = new IO::Handle),
        status => ($handle{'status'} = new IO::Handle),
    );

    eval {
        my $method = $type eq 'private'? 'list_secret_keys': 'list_public_keys';
        my $pid = _safe_run_child { $gnupg->$method( handles => $handles, command_args => [ $email ]  ) };
        waitpid $pid, 0;
    };

    my @info = readline $handle{'output'};
    close $handle{'output'};

    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $@ || $? ) {
        $res{'message'} = $@? $@: "gpg exitted with error code ". ($? >> 8);
        return %res;
    }

    @info = ParseKeysInfo( @info );
    $res{'info'} = $info[0];
    return %res;
}

sub ParseKeysInfo {
    my @lines = @_;

    my @res = ();
    foreach my $line( @lines ) {
        chomp $line;
        my ($tag, $line) = split /:/, $line, 2;
        if ( $tag eq 'pub' ) {
            my %info;
            @info{ qw(
                Trust KeyLenght Algorithm Key
                Created Expire Empty OwnerTrust
                Empty Empty KeyCapabilities Other
            ) } = split /:/, $line, 12;
            $info{'Trust'} = _ConvertTrustChar( $info{'Trust'} );
            $info{'OwnerTrust'} = _ConvertTrustChar( $info{'OwnerTrust'} );
            $info{ $_ } = _ParseDate( $info{ $_ } )
                foreach qw(Created Expire);
            push @res, \%info;
        }
        elsif ( $tag eq 'sec' ) {
            my %info;
            @info{ qw(
                Empty KeyLenght Algorithm Key
                Created Expire Empty OwnerTrust
                Empty Empty KeyCapabilities Other
            ) } = split /:/, $line, 12;
            $info{'OwnerTrust'} = _ConvertTrustChar( $info{'OwnerTrust'} );
            $info{ $_ } = _ParseDate( $info{ $_ } )
                foreach qw(Created Expire);
            push @res, \%info;
        }
        elsif ( $tag eq 'uid' ) {
            my %info;
            @info{ qw(Trust Created Expire String) }
                = (split /:/, $line)[0,4,5,8];
            $info{ $_ } = _ParseDate( $info{ $_ } )
                foreach qw(Created Expire);
            push @{ $res[-1]{'User'} ||= [] }, \%info;
        }
        elsif ( $tag eq 'fpr' ) {
            $res[-1]{'Fingerprint'} = (split /:/, $line, 10)[8];
        }
    }
    return @res;
}

{
    my %mapping = (
        o => 'Unknown (this value is new to the system)', #loc
        # deprecated
        d   => "The key has been disabled", #loc
        r   => "The key has been revoked", #loc
        e   => "The key has expired", #loc
        '-' => 'Unknown (no trust value assigned)', #loc
        #gpupg docs says that '-' and 'q' may safely be treated as the same value
        q   => 'Unknown (no trust value assigned)', #loc
        n   => "Don't trust this key at all", #loc
        m   => "There is marginal trust in this key", #loc
        f   => "The key is fully trusted", #loc
        u   => "The key is ultimately trusted", #loc
    );
    sub _ConvertTrustChar {
        my $value = shift;
        return $mapping{'-'} unless $value;

        $value = substr $value, 0, 1;
        return $mapping{ $value } || $mapping{'o'};
    }
}

sub _ParseDate {
    my $value = shift;
    # never
    return $value unless $value;

    require RT::Date;
    my $obj = RT::Date->new( $RT::SystemUser );
    # unix time
    if ( $value =~ /^\d+$/ ) {
        $obj->Set( Value => $value );
    } else {
        $obj->Set( Format => 'unknown', Value => $value, Timezone => 'utc' );
    }
    return $obj;
}

1;

# helper package to avoid using temp file
package IO::Handle::CRLF;

use strict;
use warnings FATAL => 'all';
use base qw(IO::Handle);

sub print {
    my ($self, @args) = (@_);
    s/\r*\n/\x0D\x0A/g foreach @args;
    return $self->SUPER::print( @args );
}

1;
