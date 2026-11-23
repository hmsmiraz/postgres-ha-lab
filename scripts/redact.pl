#!/usr/bin/perl
# Redact secret-shaped values and the owner's company and project identifiers from a text log,
# line by line (the line count never changes).
# Usage: perl scripts/redact.pl INPUT > OUTPUT   (per-rule counts go to STDERR)
# Variable references, placeholders, short words and prose are left alone on purpose.
use strict;
use warnings;

my %n;
my $in_key = 0;
# The names are assembled from pieces so that this file does not contain them.
my $ORG = join('', 'clou', 'dly') . '|' . join('', 'rev', 'ora');
my $K_AWS    = '[REDACTED:aws-access-key-id]';
my $K_GH     = '[REDACTED:github-token]';
my $K_SLACK  = '[REDACTED:slack-token]';
my $K_BEARER = '[REDACTED:bearer-token]';
my $K_URI    = '[REDACTED:uri-password]';
my $K_VAL    = '[REDACTED:value]';
my $K_KEY    = '[REDACTED:private-key-line]';
my $K_ORG    = '[REDACTED:company]';

while (my $line = <>) {
    my $is_begin = ($line =~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) ? 1 : 0;
    my $is_end   = ($line =~ /-----END [A-Z ]*PRIVATE KEY-----/) ? 1 : 0;
    # R2: inside a block only base64 text, PEM header lines and the markers stay in the block.
    if ($in_key && !$is_begin && !$is_end && $line !~ /^[A-Za-z0-9+\/=]{4,}\s*$/ && $line !~ /^(?:Proc-Type|DEK-Info):/) {
        $in_key = 0;
    }
    if ($in_key || $is_begin) {
        my $end = ($line =~ /-----END [A-Z ]*PRIVATE KEY-----/) ? 1 : 0;
        $line =~ s/^[^\r\n]*/$K_KEY/;
        $n{'private-key-line'}++;
        $in_key = $end ? 0 : 1;
        print $line;
        next;
    }
    $n{'aws-access-key-id'} += (($line =~ s/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/$K_AWS/g) || 0);
    $n{'github-token'} += (($line =~ s/\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})/$K_GH/g) || 0);
    $n{'slack-token'} += (($line =~ s/\bxox[abprs]-[A-Za-z0-9-]{10,}/$K_SLACK/g) || 0);
    $n{'bearer-token'} += (($line =~ s/(Bearer )[A-Za-z0-9._~+\/=-]{20,}/$1$K_BEARER/g) || 0);
    $n{'uri-password'} += (($line =~ s!([A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9._~%-]+:)[^@/\s\$<>()\[\]'"]{4,}@!$1$K_URI\@!g) || 0);
    $n{'value'} += (($line =~ s/((?:password|passwd|secret|token|api[_-]?key|access[_-]?key)["']?[ \t]*[=:][ \t]*["']?)(?![\$<\[:(]|\[REDACTED)(?=[^\s"',;]*\d)[^\s"',;]{12,}/$1$K_VAL/gi) || 0);
    $n{'company'} += (($line =~ s/(?:[A-Za-z0-9._%+-]+\@)?(?:[A-Za-z0-9-]+\.)*(?:${ORG})(?:\.[A-Za-z]{2,}){0,2}\b/$K_ORG/gi) || 0);
    print $line;
}
print STDERR join(' ', map { "$_=$n{$_}" } grep { $n{$_} } sort keys %n), "\n" if %n;
