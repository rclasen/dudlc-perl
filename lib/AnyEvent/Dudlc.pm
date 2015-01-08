#
# Copyright (c) 2015 Rainer Clasen
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms described in the file LICENSE included in this
# distribution.
#

=pod

=head1 NAME

AnyEvent::Dudlc - access to dudld jukebox

=head1 SYNOPSIS

 use AnyEvent::Dudulc;

 my $dudl = AnyEvent::Dudulc->new(
	host	=> $addr,
	user	=> 'login',
	pass	=> 'pass',
	on_<whaterver> => sub { print "got <whatever> callback\n"; },
 );

 # then, within your event loop:
 ...
	print "status: ".$dudl->status."\n";
	$dudl->play( sub { print "sent play\n" } );
	$dudl->pause;

=head1 DESCRIPTION

client access to the dudld jukebox.

=head1 CONSTRUCTOR

=over 4

=item new()

=over 4

=item host	=> $address_or_name

TODO

=item port	=> $port

=item user	=> $user,

=item pass	=> $password,

=item reconnect	=> $reconnect_interval

=item timeout	=> $command_timeout

=back

=back

=head1 METHODS

=over 4

=item push( $raw_command, $cb->( $ok, \@data ) )

send a raw command to dudl and provide result to callback. 

=item TODO

=back

=head1 CALLBACKS

=over 4

=item on_TODO

=back

=cut
package AnyEvent::Dudlc;

use warnings;
use strict;

use base 'Object::Event'; # TODO: really?
use Carp;
use AnyEvent;
use AnyEvent::Handle;

our $VERSION = 0.01;

#sub DEBUG(){0}
sub DEBUG(){1}

sub new {
	my( $proto, %a ) = @_;

	my $self = bless {
		host	=> $a{host},
		port	=> $a{port}||4445,
		user	=> $a{user},
		pass	=> $a{pass},
		reconnect	=> $a{reconnect}||10,
		timeout	=> $a{timeout}||60,
		sock	=> undef,
		rwatch	=> undef,
		queue	=> [],
		response	=> [],
		active	=> undef,
	}, ref $proto || $proto;

	return $self;
}

sub DESTROY {
	my( $self ) = @_;

	$self->{rwatch} = undef;
	$self->disconnect;
	return;
}

sub disconnect {
	my( $self, $msg ) = @_;

	DEBUG && print STDERR "disconnect: $msg\n";
	if( $self->{sock} ){
		$self->event( 'error', $msg ) if $msg;
		$self->event( 'disconnect' );
		$self->{sock}->destroy;
	}

	$self->{active} = undef;
	$self->{response} = [];
	$self->{queue} = [];
	$self->{sock} = undef;

	return;
}

sub connect {
	my( $self ) = @_;

	$self->disconnect
		if $self->{sock};

	$self->{rwatch} = undef;
	$self->event('connecting');

	$self->{active} = {
		cmd	=> 'connect',
		cb	=> sub {
			my( $ok, $d ) = @_;

			if( !$ok ){
				$self->disconnect( "no greeting");
				return;
			}

			DEBUG && print STDERR "greeting: ".$d->[0]."\n";
			my( $id, $ma, $mi ) = split/\s/,$d->[0];

			if( $id ne 'dudld' ){
				$self->disconnect( "bad greeting");
				return;
			}

			if( $ma !=2 ){
				$self->disconnect( "bad protocol version: $ma.$mi");
				return;
			}

			$self->login;
		},
	};

	$self->{sock} = AnyEvent::Handle->new(
		connect		=> [$self->{host}, $self->{port}],
		timeout		=> $self->{timeout},
		keepalive	=> 1,
		on_connect	=> sub {
			my( $h, $host, $port, $retry ) = @_;
			$self->event( 'connected' );
			$h->push_read( line => sub { $self->_read($_[1]) } );
		},
		on_timeout	=> sub {
			$self->{active}
				or return;
			$self->disconnect( 'command timed out' );
		},
		on_error	=> sub {
			my( $h, $fatal, $msg ) = @_;
			$self->disconnect( $msg );
			$self->start_reconnect;
		},
		on_eof		=> sub {
			$self->disconnect( 'EOF' );
			$self->start_reconnect;
		},
	);

	return 1;
}

sub start_reconnect {
	my( $self ) = @_;

	$self->{reconnect}
		or return;

	$self->{rwatch} = AnyEvent->timer(
		after		=> $self->{reconnect},
		cb		=> sub { $self->connect },
	);

	return;
}

my $re_line = qr/^(\d{3})(?:([ -])(.*))?/;

sub code_ok($){$_[0]>=200 && $_[0]<=399 };
sub code_bcast($){$_[0]>=600 && $_[0]<=699 };

sub _read {
	my( $self, $line ) = @_;

	$self->{sock}
		or return;

	#DEBUG && print STDERR "got line: $line\n";
	my( $scode, $cont, $data ) = $line =~ /$re_line/;
	DEBUG && print STDERR "got ok=$scode, cont=$cont, data=$data\n";
	if( ! defined $scode ){
		$self->disconnect( "bad response: $line");
		return;
	}

	my $code = int $scode;
	if( code_bcast($code) ){
		$self->_done_bcast( $code, $data );
	} else {
		push @{$self->{response}}, $data;
		$self->_done( code_ok($code) ) unless $cont eq '-';
	}

	# wait... if there wasn't an error
	$self->{sock}->push_read( line => sub { $self->_read( $_[1] ) } )
		if $self->{sock};

	return;
}

sub _done {
	my( $self, $code ) = @_;

	my $a = $self->{active}
		or return;

	DEBUG && print STDERR "_done, ok=$code: $a->{cmd}\n";
	$a->{cb} && $a->{cb}->($code, $self->{response});
	$self->{response} = [];
	$self->{active} = undef;

	$self->_next;
}

sub _done_bcast {
	my( $self, $code, $data ) = @_;

	# TODO: analyze bcast: status, curtrack
}

sub _next {
	my( $self ) = @_;

	if( ! $self->{sock} ){
		$self->connect;
		return;
	}

	$self->{active}
		and return;

	my $a = $self->{active} = shift @{$self->{queue}}
		or return;

	DEBUG && print STDERR "_next: ".$a->{cmd}."\n";

	$self->{sock}->push_write( $a->{cmd}."\n" );
}

sub unshift {
	my( $self, $cmd, $cb ) = @_;

	unshift @{$self->{queue}}, {
		cmd	=> $cmd,
		cb	=> $cb,
	};

	$self->_next;
	return 1;
}

sub push {
	my( $self, $cmd, $cb ) = @_;

	push @{$self->{queue}}, {
		cmd	=> $cmd,
		cb	=> $cb,
	};

	$self->_next;
	return 1;
}

sub login {
	my( $self, $cb ) = @_;

	$self->unshift( "user $self->{user}", sub {
		if( !$_[0] ){
			$self->disconnect( "login failed");
			return;
		}

		$self->unshift( "pass $self->{pass}", sub {
			if( !$_[0] ){
				$self->disconnect( "login failed");
				return;
			}

			$self->event('authenticated');
			$cb && $cb->(@_);
		});
	});
};

# TODO: actual commands: status, play, pause, next, sfilterset

1;

__END__

=head1 AUTHOR

Rainer Clasen

=head1 SEE ALSO

dudld, dudlc

=cut
