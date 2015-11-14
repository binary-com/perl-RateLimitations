# NAME

RateLimitations - manage per-service rate limitations

# SYNOPSIS

    use RateLimitations qw(within_rate_limits);

    if (within_rate_limits({service => 'my_service', 'consumer' => 'consumer_id'}) {
       # consumer_id has not violated the rate limits for my_service on this server
       provide_service();
    }

# DESCRIPTION

RateLimitations is a module to help enforce per-service rate limits.

The rate limits are checked via a backing Redis store.  Its persistence allows for
multiple processes to maintain a shared view of resource usage.  Acceptable rates
are defined in the `share/rate_limits.yml` file.

Several utility functions are provided to help examine the inner state to help confirm
proper operation.

Nothing is exported from this package by default.

# FUNCTIONS

- within\_rate\_limits({service => $service, consumer => $consumer\_id})

    Returns **1** if `$consumer_id` is permitted further access to `$service`
    under the rate limiting rules for the service; **0** is returned if this
    access would exceed those limits.

    Will croak unless both elements are supplied and `$service` is valid.

    Note that this call will update the known request rate, even if it eventually
    determines that the request is not within limits.  This is a conservative approach
    since we cannot know for certain how the results of this call are used. As such,
    it is best to use this call **only** when legitimately gating service access and
    to allow a bit of extra slack in the permitted limits.

- verify\_rate\_limits\_file()

    Attempts to load the `share/rate_limits.yml` file and confirm that its contents make
    sense.  It parses the file in much the same way as importing the module, with additional
    sanity checks on the supplied rates.

    Returns **1** if the file apears to be ok; **0** otherwise.

- rate\_limited\_services()

    Returns an array of all known services which have applied rate limits.

- rate\_limits\_for\_service($service)

    Returns an array of rate limits applied to requests for a known `$service`.
    Each member of the array is an array reference with two elements:

        [number_of_seconds, number_of_accesses_permitted_in_those_seconds]

- all\_service\_consumers()

    Returns a hash reference with all services and their consumers.  May be useful
    for verifying consumer names are well-formed.

        { service1 => [consumer1, consumer2],
          service2 => [consumer1, consumer2],
        }

- flush\_all\_service\_consumers()

    Clears the full list of consumers.  Returns the number of items cleared.

# AUTHOR

Binary.com <perl@binary.com>

# COPYRIGHT

Copyright 2015-

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO
