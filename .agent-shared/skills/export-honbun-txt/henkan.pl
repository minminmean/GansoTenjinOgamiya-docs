#!/usr/bin/perl
# A_本編/*.md → 投稿用テキスト。ルビと傍点は Z_その他/変換辞書/ の TSV を読んで適用する。
# 使い方: perl henkan.pl [--dry|--ledger] <辞書ディレクトリ> <出力先ディレクトリ> <なろう|カクヨム> <A_本編/*.md ...>
#   既定    : 渡した md だけを変換して書き出す。一話だけ渡してよい（単話出力）。
#   --dry   : txt を書かず、変換の記録だけ出す。辞書を足したときの波及検査に使う。
#   --ledger: 通しルビの初出を全話から数え直し、通し初出.tsv を書き直す。txt は書かない。
# 変換の記録は STDOUT に TSV（話/行/種別/変換前/変換後）で出す。
# 出力するファイル名には変換先ごとの接頭辞が付く（narou_ / kkym_）。
#
# 辞書ディレクトリに置く四枚（どれも一行目が見出し、区切りはタブ、CRLF、UTF-8）:
#   読み.tsv        分類 / 語 / ルビ / 通し / 備考
#   通し初出.tsv    語 / 初出の話           ← --ledger が書き直す唯一のファイル
#   位置指定.tsv    語 / 話 / 行の目印
#   傍点.tsv        話 / 語 / 文脈（文脈は読むだけの覚え書きで、変換には使わない）
#
# 「通し」の語（連載を通して一度だけ振る語）は、通し初出.tsv に書いてある話でだけ振る。
# だから前の話を読まなくても単話で書き出せる。判断の規則は Z_その他/テキスト変換規則.md。
use strict;
use warnings;
use utf8;
use Encode qw(decode_utf8 encode_utf8);
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my ($ledger, $dry) = (0, 0);
while (@ARGV && $ARGV[0] =~ /^--/) {
  my $o = shift @ARGV;
  if    ($o eq '--ledger') { $ledger = 1 }
  elsif ($o eq '--dry')    { $dry = 1 }
  else { die "知らない指定: $o\n" }
}
my ($dictdir, $outdir, $mode, @files) = @ARGV;
die "使い方: henkan.pl [--dry|--ledger] <辞書ディレクトリ> <出力先> <なろう|カクヨム> <md...>\n" unless @files;
die "辞書ディレクトリが無い: $dictdir\n" unless -d $dictdir;
$mode = decode_utf8($mode);
my %PREFIX = ("なろう" => "narou_", "カクヨム" => "kkym_");
die "変換先は なろう か カクヨム\n" unless exists $PREFIX{$mode};
my $prefix = $PREFIX{$mode};

# ---- 辞書ディレクトリの TSV を読む ----
# 一行目は見出し。空行は読み飛ばす。欠けた列は空として扱う
sub dictpath {
  # @ARGV はバイト、ファイル名の literal は文字。混ぜるとパスが化けるのでバイトに揃える
  my ($name) = @_;
  return $dictdir . "/" . encode_utf8($name);
}
sub read_tsv {
  my ($name, $need) = @_;
  my $path = dictpath($name);
  open(my $fh, "<:encoding(UTF-8)", $path) or die decode_utf8($dictdir) . "/$name: $!\n";
  my @rows; my $head = 0;
  while (my $l = <$fh>) {
    $l =~ s/\r?\n\z//;
    next if $l eq '';
    unless ($head) { $head = 1; next }
    my @c = split(/\t/, $l, -1);
    push @c, ("") x ($need - @c) if @c < $need;
    die decode_utf8($dictdir) . "/$name の $.行目: 列が多い（$need 列のはず）\n" if @c > $need;
    push @rows, \@c;
  }
  close $fh;
  die decode_utf8($dictdir) . "/$name に一行も無い\n" unless @rows;
  return @rows;
}

my (%ruby, %through, %through_ep, %anchor, @bouten);
for my $r (read_tsv("読み.tsv", 5)) {
  my (undef, $word, $rep, $t) = @$r;
  next if $word eq '' || $rep eq '';
  $ruby{$word} = $rep;
  $through{$word} = 1 if $t ne '';
}
for my $r (read_tsv("通し初出.tsv", 2)) {
  $through_ep{$r->[0]} = $r->[1] if $r->[1] ne '';
}
for my $r (read_tsv("位置指定.tsv", 3)) {
  $anchor{$r->[0]} = { ep => $r->[1], mark => $r->[2] } if $r->[2] ne '';
}
for my $r (read_tsv("傍点.tsv", 3)) {
  push @bouten, { ep => $r->[0], word => $r->[1] } if $r->[1] ne '';
}
warn "辞書 " . scalar(keys %ruby) . " 語（通し " . scalar(keys %through) . "、位置指定 " . scalar(keys %anchor) . "）、傍点の特例 " . scalar(@bouten) . " 件\n";
# 台帳に行の無い「通し」の語は、単話で書き出したときに振られない。必ず気づけるようにする
unless ($ledger) {
  for my $w (sort keys %through) {
    warn "  ! 通し初出.tsv に行が無い: $w\n" unless defined $through_ep{$w};
  }
}
# 長い語から当てる。短い語が長い語を食い割らないように
my @order = sort { length($b) <=> length($a) || $a cmp $b } keys %ruby;

# ---- 挿入済みの記法を退避する。以降の置換がその中に食い込まないように ----
my @slot;
sub stash { push @slot, $_[0]; return "\x{E000}" . $#slot . "\x{E001}"; }
sub expand { my $s = shift; $s =~ s/\x{E000}(\d+)\x{E001}/$slot[$1]/g; return $s; }

# その位置が、より長い見出し語の内側に入っていないか
sub covered {
  my ($s, $p, $len, $order) = @_;
  for my $k (@$order) {
    next if length($k) <= $len;
    my $q = -1;
    while (($q = index($s, $k, $q + 1)) >= 0) {
      return 1 if $q <= $p && $p + $len <= $q + length($k);
    }
  }
  return 0;
}

sub bouten_form {
  my ($s) = @_;
  return "\x{300A}\x{300A}$s\x{300B}\x{300B}" if $mode eq "カクヨム";
  return join("", map { "\x{FF5C}$_\x{300A}\x{30FB}\x{300B}" } split(//, $s));
}

# ルビの形は両面とも同じものを出すので、いちばん厳しいなろうの上限（十文字）で見張る
sub check_len {
  my ($src, $base, $yomi) = @_;
  warn "  ! 親文字が十文字を超える: $src\n" if length($base) > 10;
  warn "  ! ルビが十文字を超える: $src\n"   if length($yomi) > 10;
}

my %done_all;                 # 「通し」の語は話をまたいで振り済みにする（全話をまとめて回したときの用心）
my (%first_ep, @first_order); # --ledger で数え直す、通しの語の初出の話
sub note_first {
  my ($w, $ep, $solo) = @_;
  return if $solo || !$through{$w} || exists $first_ep{$w};
  $first_ep{$w} = $ep;
  push @first_order, $w;
}
for my $file (@files) {
  my $disp = decode_utf8($file); $disp =~ s{.*/}{}; $disp =~ s/\.md$//;
  my $base = $file; $base =~ s{.*/}{}; $base =~ s/\.md$//;
  open(my $in, "<:encoding(UTF-8)", $file) or die "$file: $!\n";
  my @lines = <$in>; close $in;
  chomp @lines; s/\r$// for @lines;
  $lines[0] =~ s/^#[ ]*// if @lines;
  s/ +$// for @lines;

  my ($ep) = @lines ? ($lines[0] =~ /^(第[一二三四五六七八九十]+話|番外)/) : ();
  $ep = "" unless defined $ep;
  my @mybouten = grep { $_->{ep} eq $ep } @bouten;
  # 番外は本編のあいだに順不同で差し込む。「通し」の語は一律に振らず、本編の勘定にも入れない
  my $solo = ($ep eq "番外");

  my %done;
  my @log;
  for my $i (0 .. $#lines) {
    my $l = $lines[$i];
    next if $l eq '';
    my $lineno = $i + 1;
    # 題の行と記帳の行（全角二字下げ以上）は触らない
    next if $i == 0 || $l =~ /^\x{3000}\x{3000}/;
    @slot = ();

    # 1. 丸括弧の読み → ルビ（初出規則より優先）
    $l =~ s{
      ([\x{3005}\x{4E00}-\x{9FFF}]+[\x{3041}-\x{309F}]*)
      \x{FF08}([\x{3041}-\x{309F}\x{30A1}-\x{30FA}\x{30FC}]+)\x{FF09}
    }{
      my ($b, $y) = ($1, $2);
      my $src = "$b\x{FF08}$y\x{FF09}";
      my $tail = "";
      while (length($b) > 1 && length($y) > 1) {
        my ($c) = $b =~ /([\x{3041}-\x{309F}])$/;
        last unless defined $c && $y =~ /\Q$c\E$/;
        $b =~ s/\Q$c\E$//; $y =~ s/\Q$c\E$//; $tail = $c . $tail;
      }
      check_len($src, $b, $y);
      my $rep = "\x{FF5C}$b\x{300A}$y\x{300B}$tail";
      push @log, [$lineno, "丸括弧", $src, $rep];
      stash($rep);
    }gex;

    # 2. 傍点（この話の特例に載っているカギ括弧のみ）
    for my $b (@mybouten) {
      my $q = "\x{300C}$b->{word}\x{300D}";
      next unless index($l, $q) >= 0;
      my $rep = bouten_form($b->{word});
      while ((my $p = index($l, $q)) >= 0) {
        substr($l, $p, length($q)) = stash($rep);
        push @log, [$lineno, "傍点", $q, $rep];
      }
    }

    # 3. ルビ（その話で初出の一回だけ）
    for my $w (@order) {
      next if $done{$w} || (!$solo && $done_all{$w});
      next if $solo && $through{$w};
      # 「通し」の語は、台帳に記した初出の話でだけ振る。ほかの話は素通し。
      # 台帳を読まずに数え直すのは --ledger のときだけ
      if (!$solo && !$ledger && $through{$w} && defined $through_ep{$w}) {
        next unless $through_ep{$w} eq $ep;
      }
      # 位置指定のある語は、その話の、その目印を含む行だけ
      if (my $a = $anchor{$w}) {
        next unless $ep eq $a->{ep} && index($l, $a->{mark}) >= 0;
      }
      # 記帳行の引用（全角空白を含むカギ括弧）の中には振らない。長さは保って伏せる
      my $mask = $l;
      $mask =~ s{(\x{300C}[^\x{300C}\x{300D}]*\x{3000}[^\x{300C}\x{300D}]*\x{300D})}
                {"\x{FFFD}" x length($1)}ge;
      # より長い見出し語の一部になっている位置は飛ばす（「大上屋」の中の「大上」など）
      my ($p, $q) = (-1, -1);
      while (($p = index($mask, $w, $p + 1)) >= 0) {
        last unless covered($mask, $p, length($w), \@order);
      }
      next if $p < 0;
      substr($l, $p, length($w)) = stash($ruby{$w});
      $done{$w} = 1;
      $done_all{$w} = 1 if $through{$w} && !$solo;
      note_first($w, $ep, $solo);
      # 長い語のルビが短い語のルビを含んでいれば、そちらも振り済みにする
      for my $k (@order) {
        next if $done{$k} || !(index($ruby{$w}, $ruby{$k}) >= 0);
        $done{$k} = 1;
        $done_all{$k} = 1 if $through{$k} && !$solo;
        note_first($k, $ep, $solo);
      }
      push @log, [$lineno, "ルビ", $w, $ruby{$w}];
    }

    $lines[$i] = expand($l);
  }

  unless ($dry || $ledger) {
    my $out = "$outdir/$prefix$base.txt";
    open(my $o, ">:encoding(UTF-8)", $out) or die "$out: $!\n";
    print $o "$_\r\n" for @lines;
    close $o;
  }
  unless ($ledger) { print join("\t", $disp, @$_), "\n" for @log; }
}

# ---- 通しルビの初出の台帳 ----
# 数え直した結果を 通し初出.tsv に書き戻す。ほかの三枚には触らない
if ($ledger) {
  my @rows = map { "$_\t$first_ep{$_}" } @first_order;
  print "$_\n" for ("語\t初出の話", @rows);

  my $ng = 0;
  for my $w (sort keys %through) {
    my $now = $first_ep{$w};
    my $rec = $through_ep{$w};
    if (!defined $rec) {
      warn "  ・台帳に行が無かった: $w（数え直すと " . (defined $now ? $now : "本編に出てこない") . "）\n"; $ng++;
    } elsif (!defined $now) {
      warn "  ・台帳にあるが本編に出てこない: $w（台帳は $rec）\n"; $ng++;
    } elsif ($now ne $rec) {
      warn "  ・台帳と食い違っていた: $w（台帳 $rec ／ 数え直すと $now）\n"; $ng++;
    }
  }
  for my $w (sort keys %through_ep) {
    next if $through{$w};
    warn "  ・通しでない語が台帳にあった: $w\n"; $ng++;
  }

  # 通し初出.tsv を書き直す。CRLF、UTF-8、一行目は見出し
  my $path = dictpath("通し初出.tsv");
  my $new  = join("", map { "$_\r\n" } ("語\t初出の話", @rows));
  open(my $rh, "<:raw", $path) or die "通し初出.tsv: $!\n";
  my $old = decode_utf8(do { local $/; <$rh> }); close $rh;

  if ($new eq $old) {
    warn "台帳は本編と合っている。通し初出.tsv は触っていない\n";
  } else {
    open(my $wh, ">:raw", $path) or die "通し初出.tsv: $!\n";
    print $wh encode_utf8($new); close $wh;
    warn "通し初出.tsv を書き直した（食い違い $ng 語）\n";
    warn "！ 通しの初出が動いた話は、txt を出し直すこと\n" if $ng;
  }
}
