package RateLimitations;

use strict;
use warnings;
our $VERSION = '0.01';

use Carp;

use Cache::RedisDB;
use File::ShareDir qw(dist_file);
use List::Util qw(all);
use Time::Duration::Concise;
use YAML::CacheLoader qw(LoadFile);

use base qw( Exporter );
our @EXPORT_OK = qw(
    all_service_consumers
    flush_all_service_consumers
    rate_limited_services
    rate_limits_for_service
    verify_rate_limits_file
    within_rate_limits
);
use constant KEYSPACE  => 'RATELIMITATIONS';    # Everything will fall under this
use constant SEPARATOR => '::';                 # How to join strings together

my $rates_file_content;
my %limits;

BEGIN {
    $rates_file_content = LoadFile(dist_file('RateLimitations', 'rate_limits.yml'));
    foreach my $svc (sort keys %$rates_file_content) {
        my @service_limits;
        foreach my $time (keys $rates_file_content->{$svc}) {
            my $ti = Time::Duration::Concise->new(interval => $time);
            my $count = $rates_file_content->{$svc}->{$time};
            push @service_limits, [$ti->seconds, $count];
        }
        @service_limits = sort { $a->[0] <=> $b->[0] } @service_limits;
        $limits{$svc} = {
            rates   => \@service_limits,
            seconds => $service_limits[-1]->[0],
            entries => $service_limits[-1]->[1],
        };
    }
}

sub verify_rate_limits_file {
    my $proper = 1;    # Assume it is proper until we find a bad entry
    foreach my $svc (sort keys %$rates_file_content) {
        my @service_limits;
        foreach my $time (keys $rates_file_content->{$svc}) {
            my $ti = Time::Duration::Concise->new(interval => $time);
            my $count = $rates_file_content->{$svc}->{$time};
            push @service_limits, [$ti->seconds, $count, $count / $ti->seconds, undef, $time];
        }
        @service_limits = sort { $a->[0] <=> $b->[0] } @service_limits;

        my @final_limits;
        while (my $this_limit = shift @service_limits) {
            my ($improper, $index) = ($this_limit->[3], $#service_limits);
            while (not $improper and $index > -1) {
                my $that_limit = $service_limits[$index];
                # This one is improper if that longer period has the same or smaller count
                $improper = 'count should be lower than ' . $that_limit->[4] . ' count' if ($that_limit->[1] <= $this_limit->[1]);
                # That one is improper if this shorter period has the same or smaller rate
                $service_limits[$index]->[3] = 'rate should be lower than ' . $this_limit->[4] . ' rate'
                    if (not $improper and $this_limit->[2] <= $that_limit->[2]);
                $index--;
            }
            if ($improper) {
                # If any entry is improper we will fail and warn.
                # We still check the rest for completeness
                $proper = 0;
                carp $svc . ' - ' . $this_limit->[4] . ' entry improper: ' . $improper;
            }
        }
    }
    return $proper;
}

sub within_rate_limits {
    my $args = shift;

    croak 'Must supply args as a hash reference' unless ref $args eq 'HASH';
    my ($service, $consumer) = @{$args}{'service', 'consumer'};
    croak 'Must supply both "service" and "consumer" arguments' unless all { defined } ($service, $consumer);
    my $limit = $limits{$service};
    croak 'Unknown service supplied: ' . $service unless $limit;

    my $redis         = Cache::RedisDB->redis;
    my $key           = _make_key($service, $consumer);
    my $within_limits = 1;
    my $now           = time;
    $redis->lpush($key, $now);    # We push first so that we hit limits more often in heavy (DoS) conditions
    $redis->ltrim($key, 0, $limit->{entries});    # Our new entry is now in index 0.. we keep 1 extra entry.
    $redis->expire($key, $limit->{seconds});
    foreach my $rate (@{$limit->{rates}}) {
        if (($redis->lindex($key, $rate->[1]) // 0) > $now - $rate->[0]) {
            $within_limits = 0;
            last;
        }
    }

    return $within_limits;
}

sub flush_all_service_consumers {
    my $redis = Cache::RedisDB->redis;
    my $count = 0;

    foreach my $key (_all_keys($redis)) {
        $count += $redis->del($key);
    }

    return $count;
}

sub _all_keys { my $redis = shift // Cache::RedisDB->redis; return @{$redis->keys(_make_key('*', '*')) // []}; }

sub rate_limited_services { return (sort keys %limits); }

sub rate_limits_for_service {
    my $service = shift // 'undef';
    my $svc_limits = $limits{$service};
    croak 'Unknown service supplied: ' . $service unless $svc_limits;

    return @{$svc_limits->{rates}};
}

sub all_service_consumers {

    my %consumers;

    foreach my $pair (map { [(split SEPARATOR, $_)[-2, -1]] } _all_keys()) {
        $consumers{$pair->[0]} //= [];
        push @{$consumers{$pair->[0]}}, $pair->[1];
    }

    return \%consumers;
}

sub _make_key {
    my ($service, $consumer) = @_;

    return join(SEPARATOR, KEYSPACE, $service, $consumer);
}

1;
__END__

=encoding utf-8

=head1 NAME

RateLimitations - manage per-service rate limitations

=head1 SYNOPSIS

 use RateLimitations qw(within_rate_limits);

 if (within_rate_limits({service => 'my_service', 'consumer' => 'consumer_id'}) {
    # consumer_id has not violated the rate limits for my_service on this server
    provide_service();
 }

=head1 DESCRIPTION

RateLimitations is a module to help enforce per-service rate limits.

The rate limits are checked via a backing Redis store.  Its persistence allows for
multiple processes to maintain a shared view of resource usage.  Acceptable rates
are defined in the F<share/rate_limits.yml> file.

Several utility functions are provided to help examine the inner state to help confirm
proper operation.

Nothing is exported from this package by default.

=head1 FUNCTIONS

=over

=item within_rate_limits({service => $service, consumer => $consumer_id})

Returns B<1> if C<$consumer_id> is permitted further access to C<$service>
under the rate limiting rules for the service; B<0> is returned if this
access would exceed those limits.

Will croak unless both elements are supplied and C<$service> is valid.

Note that this call will update the known request rate, even if it eventually
determines that the request is not within limits.  This is a conservative approach
since we cannot know for certain how the results of this call are used. As such,
it is best to use this call B<only> when legitimately gating service access and
to allow a bit of extra slack in the permitted limits.

=item verify_rate_limits_file()

Attempts to load the F<share/rate_limits.yml> file and confirm that its contents make
sense.  It parses the file in much the same way as importing the module, with additional
sanity checks on the supplied rates.

Returns B<1> if the file apears to be ok; B<0> otherwise.

=item rate_limited_services()

Returns an array of all known services which have applied rate limits.

=item rate_limits_for_service($service)

Returns an array of rate limits applied to requests for a known C<$service>.
Each member of the array is an array reference with two elements:

    [number_of_seconds, number_of_accesses_permitted_in_those_seconds]

=item all_service_consumers()

Returns a hash reference with all services and their consumers.  May be useful
for verifying consumer names are well-formed.

    { service1 => [consumer1, consumer2],
      service2 => [consumer1, consumer2],
    }

=item flush_all_service_consumers()

Clears the full list of consumers.  Returns the number of items cleared.

=back

=head1 AUTHOR

Binary.com E<lt>perl@binary.comE<gt>

=head1 COPYRIGHT

Copyright 2015-

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut
