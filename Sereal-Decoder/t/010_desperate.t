#!perl
use strict;
use warnings;
use Sereal::Decoder qw(decode_sereal);
use Sereal::Decoder::Constants qw(:all);
use Scalar::Util qw(weaken);
use Data::Dumper;

use constant FBIT => 128;

# These tests are extraordinarily basic, badly-done and really just
# for basic sanity testing during development.

use Test::More;

sub array {
  chr(SRL_HDR_ARRAY) . varint(0+@_) . join("", @_) . chr(SRL_HDR_TAIL)
}

sub array_fbit {
  chr(SRL_HDR_ARRAY+FBIT) . varint(0+@_) . join("", @_) . chr(SRL_HDR_TAIL)
}

sub varint {
  my $n = shift;
  my $out = '';
  while ($n >= 0x80) {
    $out .= chr( ($n & 0x7f) | 0x80 );
    $n >>= 7;
  }
  $out .= chr($n);
  return $out;
}

my $hdr = SRL_MAGIC_STRING . chr(SRL_PROTOCOL_VERSION) . chr(0);


my $ary_ref_for_repeating = [5,6];
my $scalar_ref_for_repeating = \9;
my $weak_thing;
$weak_thing = [\$weak_thing, 1];
weaken($weak_thing->[0]);

my @basic_tests = (
  # warning: this hardcodes the POS/NEG headers
  [1, chr(0b0000_0001), "encode 1"],
  [0, chr(0b0000_0000), "encode 0"],
  [-1, chr(0b0001_0000), "encode -1"],
  [undef, chr(SRL_HDR_UNDEF), "encode undef"],
  ["", chr(0b0100_0000), "encode empty string"],
  ["1", chr(0b0100_0001) . "1", "encode string '1'"],
  ["91a", chr(0b0100_0011) . "91a", "encode string '91a'"],
  [\1, chr(SRL_HDR_REF).varint(0).chr(0b0000_0001), "scalar ref to int"],
  [[], array(), "empty array ref"],
  [[1,2,3], array(chr(0b0000_0001), chr(0b0000_0010), chr(0b0000_0011)), "array ref"],
  [1000, chr(SRL_HDR_VARINT).varint(1000), "large int"],
  [ [1..1000],
    array(
      (map chr, (1..SRL_POS_MAX_SIZE)),
      (map chr(SRL_HDR_VARINT) . varint($_), ((SRL_POS_MAX_SIZE+1) .. 1000))
    ),
    "array ref with pos and varints"
  ],
  [{}, chr(SRL_HDR_HASH).varint(0).chr(SRL_HDR_TAIL), "empty hash ref"],
  [{foo => "baaaaar"},
       chr(SRL_HDR_HASH).varint(1)
      .chr(0b0100_0111)."baaaaar"
      .chr(0b0100_0011)."foo"
      .chr(SRL_HDR_TAIL)
      , "simple hash ref"],
  [$scalar_ref_for_repeating, chr(SRL_HDR_REF).varint(0).chr(0b0000_1001), "scalar ref to constant"],
  [[$scalar_ref_for_repeating, $scalar_ref_for_repeating],
    do {
      my $content = chr(SRL_HDR_ARRAY) .varint(2);
      $content   .= chr(SRL_HDR_REF);
      $content   .= chr(0);
      my $pos = length($hdr) + length($content);

      $content    .= chr(0b1000_1001)
                    .chr(SRL_HDR_REF)
                    .varint($pos)
                    .chr(SRL_HDR_TAIL);
      $content
    }, "repeated substructure (REUSE): scalar ref"],
  [[$ary_ref_for_repeating, $ary_ref_for_repeating],
    do {
      my $content = chr(SRL_HDR_ARRAY)
                    .varint(2);
      my $pos = length($hdr) + length($content);
      $content   .= array_fbit(chr(0b0000_0101), chr(0b0000_0110))
                    .chr(SRL_HDR_REUSE)
                    .varint($pos)
                    .chr(SRL_HDR_TAIL);
      $content
    }, "repeated substructure (REUSE): array"],
  [[\$ary_ref_for_repeating, [1, $ary_ref_for_repeating]],
    do {
      my $content = chr(SRL_HDR_ARRAY)
                    . varint(2)
                    . chr(SRL_HDR_REF)
                    . chr(0);
      my $pos = length($hdr) + length($content);
      $content   .= array_fbit(
                        chr(0b0000_0101),
                        chr(0b0000_0110)
                    )
                 . array(
                        chr(0b0000_0001),
                        chr(SRL_HDR_REUSE) . varint($pos)
                   )
                 . chr(SRL_HDR_TAIL);
      $content
    }, "repeated substructure (REUSE): asymmetric"],
  [
    $weak_thing,
    chr(SRL_HDR_ARRAY + FBIT)
    .varint(2)
    .chr(SRL_HDR_PAD)
    .chr(SRL_HDR_REF)
    .varint(0)
    .chr(SRL_HDR_REUSE)
    .varint(5)
    .chr(0b0000_0001)
    .chr(SRL_HDR_TAIL),
    "weak thing copy (requires PAD)"
  ],
  [
    \$weak_thing,
    chr(SRL_HDR_REF)
    .varint(0)
    .chr(SRL_HDR_ARRAY + FBIT)
    .varint(2)
    .chr(SRL_HDR_WEAKEN)
    .chr(SRL_HDR_REF)
    .varint(7)
    .chr(0b0000_0001)
    .chr(SRL_HDR_TAIL),
    "weak thing ref"
  ],
  sub { \@_ } ->(
    $weak_thing,
    chr(SRL_HDR_ARRAY + FBIT)
    .varint(2)
    .chr(SRL_HDR_WEAKEN)
    .chr(SRL_HDR_REF)
    .varint(5)
    .chr(0b0000_0001)
    .chr(SRL_HDR_TAIL),
    "weak thing alias"
   ),
  [
    do { my @array; $array[0]=\$array[1]; $array[1]=\$array[0]; \@array },
    chr(SRL_HDR_ARRAY)
    .varint(2)
    .chr(SRL_HDR_WEAKEN)
    .chr(SRL_HDR_REF)
    .varint(5)
    .chr(0b0000_0001)
    .chr(SRL_HDR_TAIL),
    "weak thing ref"
  ],

);

run_tests("plain");
done_testing();
diag("All done folks!");

sub run_tests {
  my ($extra_name, $opt_hash) = @_;
  foreach my $bt (@basic_tests) {
    my ($in, $exp, $name) = @$bt;
    $exp = "$hdr$exp";
    my $out;
    my $ok= eval { $out = decode_sereal($exp); 1};
    ok($ok,"($extra_name) did not die: $name")
        or do {
            diag "$@"||"Zombie error";
            diag "input=", Data::Dumper::qquote($exp);
            next;
        };
    ok(defined($out)==defined($in), "($extra_name) defined: $name");
    is_deeply($out, $in,"($extra_name) is_deeply: $name");
  }
}
