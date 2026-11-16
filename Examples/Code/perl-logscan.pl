#!/usr/bin/env perl
use strict;
use warnings;

# Count log levels from stdin or files.
my @levels = qw(DEBUG INFO WARN ERROR);
my %count;
while (my $line = <>) {
    next unless $line =~ m{\b(DEBUG|INFO|WARN|ERROR)\b};
    (my $clean = $line) =~ s{\s+$}{};
    $count{$1}++;
}

print <<"END";
Levels seen: @{[ scalar keys %count ]} of $#levels + 1
END

for my $level (sort { $count{$b} <=> $count{$a} } keys %count) {
    printf "%-5s %6d\n", $level, $count{$level};
}

__END__

=head1 NAME

logscan - count log levels

=cut
