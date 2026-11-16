#!/usr/bin/env perl
use strict;
use warnings;

# Count log levels from stdin or files.
my %count;
while (my $line = <>) {
    next unless $line =~ /\b(DEBUG|INFO|WARN|ERROR)\b/;
    $count{$1}++;
}

for my $level (sort { $count{$b} <=> $count{$a} } keys %count) {
    printf "%-5s %6d\n", $level, $count{$level};
}
