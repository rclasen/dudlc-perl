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

=item push_raw( $raw_command, $cb->( $ok, \@data ) )

send a raw command to dudl and provide result to callback. 

=item TODO

=back

=head1 CALLBACKS

=over 4

=item on_connected

=item on_authenticated

=item on_disconnect

=itme on_error

=item on_status

=item on_track

=back

=cut
package AnyEvent::Dudlc;

use warnings;
use strict;

use Carp;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Encode;

our $VERSION = 0.04;

# inlined: sub DEBUG(){1 or 0} based on ENV:
BEGIN {
	no strict 'refs';
	*DEBUG = $ENV{ANYEVENT_DUDLC_DEBUG} ? sub(){1} : sub(){0};
}
sub DPRINT { DEBUG && print STDERR $_[0]."\n"; }

sub new {
	my( $proto, %a ) = @_;

	my $self = bless {
		host	=> $a{host},
		port	=> $a{port}||4445,
		user	=> $a{user},
		pass	=> $a{pass},
		reconnect	=> $a{reconnect}||10,
		timeout	=> $a{timeout}||30,
		# connection callbacks:
		on_connected	=> $a{on_connected},
		on_authenticated	=> $a{on_authenticated},
		on_disconnect	=> $a{on_disconnect},
		on_error	=> $a{on_error},
		# bcast callbacks:
		on_status	=> $a{on_status},
		on_track	=> $a{on_track},
		on_filter	=> $a{on_filter},
		# internal:
		sock	=> undef,
		rwatch	=> undef,
		queue	=> [],
		response	=> [],
		active	=> undef,
	}, ref $proto || $proto;

	$self->connect;

	return $self;
}

sub DESTROY {
	my( $self ) = @_;

	DEBUG && DPRINT "destroy $self";
	$self->{rwatch} = undef;
	$self->disconnect('destroy');
	return;
}

sub disconnect {
	my( $self, $msg ) = @_;

	DEBUG && DPRINT "disconnect: $msg";
	if( $self->{sock} ){
		$self->{on_error} && $self->{on_error}->($msg, $self) if $msg;
		$self->{on_disconnect} && $self->{on_disconnect}->($self);
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

	$self->disconnect('reconnect')
		if $self->{sock};

	$self->{rwatch} = undef;

	$self->{active} = {
		cmd	=> 'connect',
		cb	=> sub {
			my( $ok, $d ) = @_;

			if( !$ok ){
				$self->disconnect( "no greeting");
				$self->start_reconnect;
				return;
			}

			DEBUG && DPRINT "greeting: ".$d->[0];
			my( $id, $ma, $mi ) = split/\s/,$d->[0];

			if( $id ne 'dudld' ){
				$self->disconnect( "bad greeting");
				$self->start_reconnect;
				return;
			}

			if( $ma !=2 ){
				$self->disconnect( "bad protocol version: $ma.$mi");
				$self->start_reconnect;
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
			$self->{on_connected} && $self->{on_connected}->($self);
			$h->push_read( line => sub { $self->_read($_[1]) } );
		},
		on_timeout	=> sub {
			$self->{active}
				or return;
			$self->disconnect( 'command timed out' );
			$self->start_reconnect;
		},
		on_error	=> sub {
			my( $h, $fatal, $msg ) = @_;
			$self->disconnect( 'socket error: '. $msg );
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

sub getsockname {
	my( $self ) = @_;

	$self->{sock}
		or return;

	my $fh = $self->{sock}->fh
		or return;

	my( $service, $local ) = AnyEvent::Socket::unpack_sockaddr( getsockname($fh) );

	return( $service, format_address($local) );
}

############################################################
# protocol handling

my $re_line = qr/^(\d{3})(?:([ -])(.*))?/;
my $re_sep = qr/\t/;

sub code_ok($){$_[0]>=200 && $_[0]<=399 };
sub code_bcast($){$_[0]>=600 && $_[0]<=699 };

our @status = qw/stopped playing paused/;
our %bcast = (
	640	=> sub { # newtrack
		my( $self, $data ) = @_;
	},
	641	=> sub {
		my( $self, $data ) = @_;
		$self->{on_status} && $self->{on_status}->('stopped', $self);
	},
	642	=> sub {
		my( $self, $data ) = @_;
		$self->{on_status} && $self->{on_status}->('paused', $self);
	},
	643	=> sub {
		my( $self, $data ) = @_;
		$self->{on_status} && $self->{on_status}->('playing', $self);
	},
	650	=> sub {
		my( $self, $data ) = @_;
		$self->{on_filter} && $self->{on_filter}->($data, $self);
	},
	# TODO: other bcast
);

sub _read {
	my( $self, $line ) = @_;

	$self->{sock}
		or return;

	#DEBUG && DPRINT "got line: $line";
	my( $scode, $cont, $data ) = $line =~ /$re_line/;
	DEBUG && DPRINT "got ok=$scode, cont=$cont, data=$data";
	if( ! defined $scode ){
		$self->disconnect( "bad response: $line");
		$self->start_reconnect;
		return;
	}
	my $u = decode('latin1', $data);

	my $code = int $scode;
	if( code_bcast($code) ){
		exists $bcast{$code}
			&& $bcast{$code}
			&& $bcast{$code}->( $self, $u );
	} else {
		if( length($data) ){
			push @{$self->{response}}, $u;
		}
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

	DEBUG && DPRINT "_done, ok=$code: $a->{cmd}";
	$a->{cb} && $a->{cb}->($code, $self->{response});
	$self->{response} = [];
	$self->{active} = undef;

	$self->_next;
}

sub _next {
	my( $self ) = @_;

	$self->{sock}
		or return;

	$self->{active}
		and return;

	my $a = $self->{active} = shift @{$self->{queue}}
		or return;

	DEBUG && DPRINT "_next: ".$a->{cmd};

	$self->{sock}->push_write( encode('latin1',$a->{cmd})."\n" );
}

############################################################
# raw commands:

sub unshift_raw {
	my( $self, $cmd, $cb ) = @_;

	unshift @{$self->{queue}}, {
		cmd	=> $cmd,
		cb	=> $cb,
	};

	$self->_next;
	return 1;
}

sub push_raw {
	my( $self, $cmd, $cb ) = @_;

	push @{$self->{queue}}, {
		cmd	=> $cmd,
		cb	=> $cb,
	};

	$self->_next;
	return 1;
}

############################################################
# actual commands:

sub login {
	my( $self, $cb ) = @_;

	$self->unshift_raw( "user $self->{user}", sub {
		if( !$_[0] ){
			$self->disconnect( "login failed");
			return;
		}

		$self->unshift_raw( "pass $self->{pass}", sub {
			if( !$_[0] ){
				$self->disconnect( "login failed");
				return;
			}

			$self->{on_authenticated} && $self->{on_authenticated}->($self);
			$cb && $cb->(@_);
		});
	});
};

sub status {
	my( $self, $cb ) = @_;

	$self->push_raw('status', sub {
		my( $ok, $d ) = @_;
		$cb && $cb->( $ok && $d->[0] < @status
			? $status[$d->[0]] : undef );
	});
}

sub play {
	my( $self, $cb ) = @_;
	$self->push_raw('play', $cb );
}

sub pause {
	my( $self, $cb ) = @_;
	$self->push_raw('pause', $cb );
}

sub stop {
	my( $self, $cb ) = @_;
	$self->push_raw('stop', $cb );
}

sub next {
	my( $self, $cb ) = @_;
	$self->push_raw('next', $cb );
}

sub sfilterlist {
	my( $self, $cb ) = @_;
	$self->push_raw('sfilterlist', ! $cb ? undef : sub {
		my( $ok, $d ) = @_;
		if( ! $ok ){
			$cb->();
			return;
		}
		my %res;
		foreach my $r ( @$d ){
			my %e;
			@e{qw/id name filter/} = split /$re_sep/, $r;
			$e{id} or next;
			$res{$e{id}} =  \%e;
		}
		$cb->(\%res);
	});
}

sub filter {
	my( $self, $cb ) = @_;
	$self->push_raw("filter", ! $cb ? undef : sub {
		my( $ok, $d ) = @_;
		if( ! $ok ){
			$cb->();
			return;
		}
		$cb->($d->[0]);
	});
}

sub filterset {
	my( $self, $filter, $cb ) = @_;
	$self->push_raw("filterset $filter", $cb );
}

# TODO: more commands

1;

__END__

=head1 AUTHOR

Rainer Clasen

=head1 SEE ALSO

dudld, dudlc

=cut
