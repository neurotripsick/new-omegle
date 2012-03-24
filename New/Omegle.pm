#!/usr/bin/perl
# Copyright (c) 2011, Mitchell Cooper
package New::Omegle;

use warnings;
use strict;
use 5.010;

use HTTP::Async;
use HTTP::Request::Common;
use JSON;

our ($VERSION, $online, @servers) = (0.6, 0);
my  $lastserver;

sub new {
    my ($class, %opts) = @_;
    $opts{async} = HTTP::Async->new;
    bless my $om = \%opts, $class;
    return $om->update;
}

sub start {
    my $om = shift;
    $om->{last_time} = time;
    $om->{async}   ||= new HTTP::Async;
    $om->{server}    = &newserver unless $om->{static};

    my $startopts = '?rcs=&spid=';

    # get ID
    $om->{async}->add(POST "http://$$om{server}/start$startopts");
    while (my $res = $om->{async}->wait_for_next_response) {
        next unless $res->content =~ m/^"(.+)"$/;
        $om->{id} = $1;
        last
    }

    $om->{stopsearching} = time() + 5 if $om->{use_likes};
    $om->request_next_event;
    return $om->{id};
}

sub newserver {
    $servers[$lastserver == $#servers ? $lastserver = 0 : ++$lastserver];
}

sub request_next_event {
    my $om = shift;
    return unless $om->{id};
    $om->post('events');
}

sub get_next_events {
    my $om = shift;
    my @f = ();
    while (my @res = $om->{async}->next_response) { push @f, \@res }
    return @f;
}

sub handle_events {
    my ($om, $data, $req_id) = @_;

    # captcha response
    if (defined $om->{pending_captcha} && $req_id == $om->{pending_captcha}) {
        delete $om->{pending_captcha};
    }

    # array of events must start with [
    return unless $data =~ m/^\[/;

    # event JSON
    my $events = JSON::decode_json($data);
    foreach my $event (@$events) {
        $om->handle_event(@$event);
    }
}

sub callback {
    my ($om, $callback) = (shift, shift);
    if (exists $om->{$callback}) {
        my $call = $om->{$callback};
        return $call->($om, @_)
    }
    return
}

sub handle_event {
    my ($om, @event) = @_;
    given ($event[0]) {

        # session established
        when ('connected') {
            $om->callback('on_connect')
        }

        # stranger said something
        when ('gotMessage') {
            $om->callback('on_chat', $event[1]);
            $om->{typing} = 0
        }

        # stranger disconnected
        when ('strangerDisconnected') {
            $om->callback('on_disconnect');
            delete $om->{id}
        }

        # stranger is typing
        when ('typing') {
            $om->callback('on_type') unless $om->{typing};
            $om->{typing} = 1
        }

        # stranger stopped typing
        when ('stoppedTyping') {
            $om->callback('on_stoptype') if $om->{typing};
            $om->{typing} = 0
        }

        # stranger has similar interests
        when ('commonLikes') {
            $om->callback('on_commonlikes', $event[1]);
        }

        # number of people online
        when ('count') {
            $online = $event[1];
            $om->callback('on_count', $event[1]);
        }

        # server requests captcha
        when (['recaptchaRequired', 'recaptchaRejected']) {
            my $rand = rand;
            my $name = $event[1];
            my $id   = $om->{async}->add(GET "http://google.com/recaptcha/api/challenge?k=$name&ajax=1");
            while (my ($res, $this_id) = $om->{async}->wait_for_next_response) {
                next   unless $id == $this_id;
                return unless $res->content =~ m/challenge : '(.+)'/;
                $om->{challenge} = $1;
                $om->callback('on_gotcaptcha', "http://www.google.com/recaptcha/api/image?c=$1");
                last
            }
        }
    }
    return 1
}

# request and handle events: put this in your main loop
sub go {
    my $om = shift;
    return unless $om->{id};
    return if (($om->{last_time} + 2) > time);

    # stop searching for common likes
    if (defined $om->{stopsearching} && $om->{stopsearching} >= time) {
        $om->post('stoplookingforcommonlikes');
        $om->callback('on_stopsearching');
        delete $om->{stopsearching};
    }

    # look for new events
	foreach my $res ($om->get_next_events) {
	    next unless $res->[0];
        $om->handle_events($res->[0]->content, $res->[1]);
    }

    $om->request_next_event;
    $om->{last_time} = time;
}

# update status
sub update {
    my $om = shift;
    $om->{async}->add(POST "http://omegle.com/status");
    my $data    = JSON::decode_json($om->{async}->wait_for_next_response->content);
    @servers    = @{$data->{servers}};
    $lastserver = $#servers;
    $online     = $data->{count};
    return $om;
}

# submit recaptcha request
sub submit_captcha {
    my ($om, $response) = @_;
    $om->{pending_captcha} = $om->post('recaptcha', [
        challenge => delete $om->{challenge},
        response  => $response
    ]);
}

# send a message
sub say {
    my ($om, $msg) = @_;
    return unless $om->{id};
    $om->post('send', [ msg => $msg ]);
}

# make it appear that you are typing
sub type {
    my $om = shift;
    return unless $om->{id};
    $om->post('typing');
}

# make it appear that you have stopped typing
sub stoptype {
    my $om = shift;
    return unless $om->{id};
    $om->post('stoptyping');
}

# disconnect
sub disconnect {
    my $om = shift;
    return unless $om->{id};
    $om->post('disconnect');
    delete $om->{id};
}

# http async post with id
sub post {
    my ($om, $event, @opts) = (shift, shift, @{+shift || []});
    $om->{async}->add(POST "http://$$om{server}/$event", [ id => $om->{id}, @opts ]);
}

1
