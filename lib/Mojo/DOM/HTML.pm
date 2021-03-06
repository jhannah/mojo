package Mojo::DOM::HTML;
use Mojo::Base -base;

use Mojo::Util qw(html_unescape xml_escape);
use Scalar::Util 'weaken';

has 'xml';
has tree => sub { ['root'] };

my $ATTR_RE = qr/
  ([^<>=\s]+)      # Key
  (?:
    \s*=\s*
    (?:
      "([^"]*?)"   # Quotation marks
    |
      '([^']*?)'   # Apostrophes
    |
      ([^>\s]*)    # Unquoted
    )
  )?
  \s*
/x;
my $END_RE   = qr!^\s*/\s*(.+)\s*!;
my $TOKEN_RE = qr/
  ([^<]*)                                           # Text
  (?:
    <\?(.*?)\?>                                     # Processing Instruction
  |
    <!--(.*?)--\s*>                                 # Comment
  |
    <!\[CDATA\[(.*?)\]\]>                           # CDATA
  |
    <!DOCTYPE(
      \s+\w+
      (?:(?:\s+\w+)?(?:\s+(?:"[^"]*"|'[^']*'))+)?   # External ID
      (?:\s+\[.+?\])?                               # Int Subset
      \s*
    )>
  |
    <(
      \s*
      [^<>\s]+                                      # Tag
      \s*
      (?:$ATTR_RE)*                                 # Attributes
    )>
  |
    (<)                                             # Runaway "<"
  )??
/xis;

# HTML elements that break paragraphs
my %PARAGRAPH = map { $_ => 1 } (
  qw(address article aside blockquote dir div dl fieldset footer form h1 h2),
  qw(h3 h4 h5 h6 header hr main menu nav ol p pre section table ul)
);

# HTML table elements with optional end tags
my %TABLE = map { $_ => 1 } qw(colgroup tbody td tfoot th thead tr);

# HTML elements without end tags
my %VOID = map { $_ => 1 } (
  qw(area base br col embed hr img input keygen link menuitem meta param),
  qw(source track wbr)
);

# HTML elements categorized as phrasing content (and obsolete inline elements)
my @PHRASING = (
  qw(a abbr area audio b bdi bdo br button canvas cite code data datalist),
  qw(del dfn em embed i iframe img input ins kbd keygen label link map mark),
  qw(math meta meter noscript object output progress q ruby s samp script),
  qw(select small span strong sub sup svg template textarea time u var video),
  qw(wbr)
);
my @OBSOLETE = qw(acronym applet basefont big font strike tt);
my %PHRASING = map { $_ => 1 } @OBSOLETE, @PHRASING;

sub parse {
  my ($self, $html) = @_;

  my $current = my $tree = ['root'];
  while ($html =~ m/\G$TOKEN_RE/gcs) {
    my ($text, $pi, $comment, $cdata, $doctype, $tag, $runaway)
      = ($1, $2, $3, $4, $5, $6, $11);

    # Text (and runaway "<")
    $text .= '<' if defined $runaway;
    push @$current, ['text', html_unescape $text] if length $text;

    # DOCTYPE
    if ($doctype) { push @$current, ['doctype', $doctype] }

    # Comment
    elsif ($comment) { push @$current, ['comment', $comment] }

    # CDATA
    elsif ($cdata) { push @$current, ['cdata', $cdata] }

    # Processing instruction (try to detect XML)
    elsif ($pi) {
      $self->xml(1) if !defined $self->xml && $pi =~ /xml/i;
      push @$current, ['pi', $pi];
    }

    # End
    next unless $tag;
    my $cs = $self->xml;
    if ($tag =~ $END_RE) { $self->_end($cs ? $1 : lc($1), \$current) }

    # Start
    elsif ($tag =~ m!([^\s/]+)([\s\S]*)!) {
      my ($start, $attr) = ($cs ? $1 : lc($1), $2);

      # Attributes
      my %attrs;
      while ($attr =~ /$ATTR_RE/g) {
        my $key = $cs ? $1 : lc($1);
        my $value = $2 // $3 // $4;

        # Empty tag
        next if $key eq '/';

        $attrs{$key} = defined $value ? html_unescape($value) : $value;
      }

      # Tag
      $self->_start($start, \%attrs, \$current);

      # Element without end tag
      $self->_end($start, \$current)
        if (!$self->xml && $VOID{$start}) || $attr =~ m!/\s*$!;

      # Relaxed "script" or "style"
      if ($start eq 'script' || $start eq 'style') {
        if ($html =~ m!\G(.*?)<\s*/\s*$start\s*>!gcsi) {
          push @$current, ['raw', $1];
          $self->_end($start, \$current);
        }
      }
    }
  }

  return $self->tree($tree);
}

sub render { $_[0]->_render($_[0]->tree) }

sub _close {
  my ($self, $current, $allowed, $scope) = @_;

  # Close allowed parent elements in scope
  my $parent = $$current;
  while ($parent->[0] ne 'root' && $parent->[1] ne $scope) {
    $self->_end($parent->[1], $current) if $allowed->{$parent->[1]};
    $parent = $parent->[3];
  }
}

sub _end {
  my ($self, $end, $current) = @_;

  # Search stack for start tag
  my $found = 0;
  my $next  = $$current;
  while ($next->[0] ne 'root') {

    # Right tag
    ++$found and last if $next->[1] eq $end;

    # Phrasing content can only cross phrasing content
    return if !$self->xml && $PHRASING{$end} && !$PHRASING{$next->[1]};

    $next = $next->[3];
  }

  # Ignore useless end tag
  return unless $found;

  # Walk backwards
  $next = $$current;
  while (($$current = $next) && $$current->[0] ne 'root') {
    $next = $$current->[3];

    # Match
    if ($end eq $$current->[1]) { return $$current = $$current->[3] }

    # Table
    elsif ($end eq 'table') { $self->_close($current, \%TABLE, $end) }

    # Missing end tag
    $self->_end($$current->[1], $current);
  }
}

sub _render {
  my ($self, $tree) = @_;

  # Text (escaped)
  my $e = $tree->[0];
  return xml_escape $tree->[1] if $e eq 'text';

  # Raw text
  return $tree->[1] if $e eq 'raw';

  # DOCTYPE
  return '<!DOCTYPE' . $tree->[1] . '>' if $e eq 'doctype';

  # Comment
  return '<!--' . $tree->[1] . '-->' if $e eq 'comment';

  # CDATA
  return '<![CDATA[' . $tree->[1] . ']]>' if $e eq 'cdata';

  # Processing instruction
  return '<?' . $tree->[1] . '?>' if $e eq 'pi';

  # Start tag
  my $start   = 1;
  my $content = '';
  if ($e eq 'tag') {
    $start = 4;

    # Open tag
    my $tag = $tree->[1];
    $content .= "<$tag";

    # Attributes
    my @attrs;
    for my $key (sort keys %{$tree->[2]}) {
      my $value = $tree->[2]{$key};

      # No value
      push @attrs, $key and next unless defined $value;

      # Key and value
      push @attrs, qq{$key="} . xml_escape($value) . '"';
    }
    my $attrs = join ' ', @attrs;
    $content .= " $attrs" if $attrs;

    # Element without end tag
    return $self->xml || $VOID{$tag} ? "$content />" : "$content></$tag>"
      unless $tree->[4];

    # Close tag
    $content .= '>';
  }

  # Render whole tree
  $content .= $self->_render($tree->[$_]) for $start .. $#$tree;

  # End tag
  $content .= '</' . $tree->[1] . '>' if $e eq 'tag';

  return $content;
}

sub _start {
  my ($self, $start, $attrs, $current) = @_;

  # Autoclose optional HTML elements
  if (!$self->xml && $$current->[0] ne 'root') {

    # "li"
    if ($start eq 'li') { $self->_close($current, {li => 1}, 'ul') }

    # "p"
    elsif ($PARAGRAPH{$start}) { $self->_end('p', $current) }

    # "head"
    elsif ($start eq 'body') { $self->_end('head', $current) }

    # "optgroup"
    elsif ($start eq 'optgroup') { $self->_end('optgroup', $current) }

    # "option"
    elsif ($start eq 'option') { $self->_end('option', $current) }

    # "colgroup", "thead", "tbody" and "tfoot"
    elsif (grep { $_ eq $start } qw(colgroup thead tbody tfoot)) {
      $self->_close($current, \%TABLE, 'table');
    }

    # "tr"
    elsif ($start eq 'tr') { $self->_close($current, {tr => 1}, 'table') }

    # "th" and "td"
    elsif ($start eq 'th' || $start eq 'td') {
      $self->_close($current, {$_ => 1}, 'table') for qw(th td);
    }

    # "dt" and "dd"
    elsif ($start eq 'dt' || $start eq 'dd') {
      $self->_end($_, $current) for qw(dt dd);
    }

    # "rt" and "rp"
    elsif ($start eq 'rt' || $start eq 'rp') {
      $self->_end($_, $current) for qw(rt rp);
    }
  }

  # New tag
  my $new = ['tag', $start, $attrs, $$current];
  weaken $new->[3];
  push @$$current, $new;
  $$current = $new;
}

1;

=encoding utf8

=head1 NAME

Mojo::DOM::HTML - HTML/XML engine

=head1 SYNOPSIS

  use Mojo::DOM::HTML;

  # Turn HTML into DOM tree
  my $html = Mojo::DOM::HTML->new;
  $html->parse('<div><p id="a">A</p><p id="b">B</p></div>');
  my $tree = $html->tree;

=head1 DESCRIPTION

L<Mojo::DOM::HTML> is the HTML/XML engine used by L<Mojo::DOM>.

=head1 ATTRIBUTES

L<Mojo::DOM::HTML> implements the following attributes.

=head2 tree

  my $tree = $html->tree;
  $html    = $html->tree(['root', ['text', 'foo']]);

Document Object Model. Note that this structure should only be used very
carefully since it is very dynamic.

=head2 xml

  my $xml = $html->xml;
  $html   = $html->xml(1);

Disable HTML semantics in parser and activate case sensitivity, defaults to
auto detection based on processing instructions.

=head1 METHODS

L<Mojo::DOM::HTML> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 parse

  $html = $html->parse('<foo bar="baz">test</foo>');

Parse HTML/XML fragment.

=head2 render

  my $xml = $html->render;

Render DOM to XML.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
