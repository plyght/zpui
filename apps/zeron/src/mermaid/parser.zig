//! Mermaid source → `Graph` (mermaid-rs-renderer `parser.rs`) for the diagram
//! kinds zeron renders: flowchart/graph, classDiagram, stateDiagram(-v2),
//! erDiagram, sequenceDiagram, pie and gantt. Other recognized headers
//! report `error.UnsupportedDiagram`; unknown input `error.UnknownDiagram`,
//! like the crate's "unknown or missing Mermaid diagram header".

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const ir = @import("ir.zig");
const Regex = @import("regex.zig").Regex;
const json5 = @import("json5.zig");

const Graph = ir.Graph;
const NodeShape = ir.NodeShape;
const trim = util.trim;
const eql = util.eql;
const startsWith = util.startsWith;
const endsWith = util.endsWith;

pub const Error = error{ OutOfMemory, InvalidSyntax, UnknownDiagram, UnsupportedDiagram, InvalidRegex };

const pipe_label_src = "^(?P<left>.+?)\\s*(?P<arrow><[-.=ox]*[-=]+[-.=ox]*>|<[-.=ox]*[-=]+[-.=ox]*|[-.=ox]*[-=]+[-.=ox]*>|[-.=ox]*[-=]+[-.=ox]*)\\|(?P<label>.+?)\\|\\s*(?P<right>.+)$";
const quoted_label_src = "^(?P<left>.+?)\\s*(?P<start><)?(?P<dash1>[-.=ox]*[-=]+[-.=ox]*)\\s+\"(?P<label>[^\"]+)\"\\s+(?P<dash2>[-.=ox]*[-=]+[-.=ox]*)(?P<end>>)?\\s*(?P<right>.+)$";
const label_arrow_src = "^(?P<left>.+?)\\s*(?P<start><)?(?P<dash1>[-.=ox]*[-=]+[-.=ox]*)\\s+(?P<label>[^<>=]+?)\\s+(?P<dash2>[-.=ox]*[-=]+[-.=ox]*)(?P<end>>)?\\s*(?P<right>.+)$";
const compact_dotted_src = "^(?P<left>.+?)\\s*(?P<start><)?(?P<dash1>[-=ox]*[-=]+[-=ox]*)\\.(?P<label>[^<>=|].*?)\\.(?P<dash2>[-.=ox]*[-=]+[-.=ox]*)(?P<end>>)?\\s*(?P<right>.+)$";
const arrow_src = "^(?P<left>.+?)\\s*(?P<arrow><[-.=ox]*[-=]+[-.=ox]*>|<[-.=ox]*[-=]+[-.=ox]*|[-.=ox]*[-=]+[-.=ox]*>|[-.=ox]*[-=]+[-.=ox]*)\\s*(?P<right>.+)$";
const arrow_token_src = "<[-.=ox]*[-=]+[-.=ox]*>|<[-.=ox]*[-=]+[-.=ox]*|[-.=ox]*[-=]+[-.=ox]*>|[-.=ox]*[-=]+[-.=ox]*";
const header_src = "^(flowchart|graph)\\s+(\\w+)";
const subgraph_src = "^subgraph\\s+(.*)$";
const init_src = "^%%\\{\\s*init\\s*:\\s*(\\{.*\\})\\s*\\}%%";

pub const Parser = struct {
    a: Allocator,
    pipe_label: Regex,
    quoted_label: Regex,
    label_arrow: Regex,
    compact_dotted: Regex,
    arrow: Regex,
    arrow_token: Regex,
    header: Regex,
    subgraph: Regex,
    init_re: Regex,
    /// The failing line / reason for `InvalidSyntax`.
    message: []const u8 = "",

    pub fn init(a: Allocator) Error!Parser {
        return .{
            .a = a,
            .pipe_label = try Regex.compile(a, pipe_label_src),
            .quoted_label = try Regex.compile(a, quoted_label_src),
            .label_arrow = try Regex.compile(a, label_arrow_src),
            .compact_dotted = try Regex.compile(a, compact_dotted_src),
            .arrow = try Regex.compile(a, arrow_src),
            .arrow_token = try Regex.compile(a, arrow_token_src),
            .header = try Regex.compile(a, header_src),
            .subgraph = try Regex.compile(a, subgraph_src),
            .init_re = try Regex.compile(a, init_src),
        };
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.message = std.fmt.allocPrint(p.a, fmt, args) catch "invalid syntax";
        return error.InvalidSyntax;
    }

    // ---------------------------------------------------------------------------------
    // Entry
    // ---------------------------------------------------------------------------------

    pub fn parse(p: *Parser, input: []const u8) Error!Graph {
        try p.validateInitDirectives(input);
        const kind = (try p.detectDiagramKind(input)) orelse {
            p.message = "unknown or missing Mermaid diagram header";
            return error.UnknownDiagram;
        };
        return switch (kind) {
            .flowchart => p.parseFlowchart(input),
            .class => p.parseClassDiagram(input),
            .state => p.parseStateDiagram(input),
            .er => p.parseErDiagram(input),
            .sequence => p.parseSequenceDiagram(input),
            .pie => p.parsePieDiagram(input),
            .gantt => p.parseGanttDiagram(input),
            else => {
                p.message = std.fmt.allocPrint(p.a, "{t} diagrams are not supported", .{kind}) catch "unsupported diagram";
                return error.UnsupportedDiagram;
            },
        };
    }

    fn validateInitDirectives(p: *Parser, input: []const u8) Error!void {
        var in_frontmatter = false;
        var it = util.lines(input);
        while (it.next()) |raw| {
            const t = trim(raw);
            if (t.len == 0) continue;
            if (eql(t, "---")) {
                in_frontmatter = !in_frontmatter;
                continue;
            }
            if (in_frontmatter) continue;
            _ = try p.parseInitDirective(t);
        }
    }

    pub fn detectDiagramKind(p: *Parser, input: []const u8) Error!?ir.DiagramKind {
        var in_frontmatter = false;
        var it = util.lines(input);
        while (it.next()) |raw| {
            const t = trim(raw);
            if (t.len == 0) continue;
            if (eql(t, "---")) {
                in_frontmatter = !in_frontmatter;
                continue;
            }
            if (in_frontmatter) continue;
            if (startsWith(t, "%%")) continue;
            const without = try stripTrailingComment(p.a, t);
            if (without.len == 0) continue;
            const lower = try util.lowerAscii(p.a, without);
            const table = [_]struct { []const u8, ir.DiagramKind }{
                .{ "sequencediagram", .sequence },   .{ "classdiagram", .class },     .{ "statediagram", .state },
                .{ "erdiagram", .er },               .{ "pie", .pie },                .{ "mindmap", .mindmap },
                .{ "journey", .journey },            .{ "timeline", .timeline },      .{ "gantt", .gantt },
                .{ "requirementdiagram", .requirement }, .{ "gitgraph", .git_graph },
            };
            for (table) |e| if (startsWithHeader(lower, e[0])) return e[1];
            for ([_][]const u8{ "c4", "c4context", "c4container", "c4component", "c4dynamic", "c4deployment" }) |k| {
                if (startsWithHeader(lower, k)) return .c4;
            }
            const table2 = [_]struct { []const u8, ir.DiagramKind }{
                .{ "sankey", .sankey },             .{ "quadrantchart", .quadrant }, .{ "zenuml", .zen_uml },
                .{ "block", .block },               .{ "packet", .packet },          .{ "kanban", .kanban },
                .{ "architecture", .architecture }, .{ "radar", .radar },            .{ "treemap", .treemap },
                .{ "xychart", .xy_chart },
            };
            for (table2) |e| if (startsWithHeader(lower, e[0])) return e[1];
            if (startsWithHeader(lower, "flowchart") or startsWithHeader(lower, "graph")) return .flowchart;
            if (try p.looksLikeFlowchartEdgeSyntax(without)) return .flowchart;
            return null;
        }
        return null;
    }

    fn startsWithHeader(line: []const u8, keyword: []const u8) bool {
        if (!startsWith(line, keyword)) return false;
        const rest = line[keyword.len..];
        if (rest.len == 0) return true;
        const d = util.decodeAt(rest, 0);
        return !(d.cp < 0x80 and std.ascii.isAlphanumeric(@intCast(d.cp)));
    }

    fn parseInitDirective(p: *Parser, t: []const u8) Error!bool {
        if (try p.init_re.captures(p.a, t)) |caps| {
            const json_str = caps.get(1) orelse return p.fail("invalid Mermaid init directive: missing config object", .{});
            if (!json5.isValid(p.a, json_str)) return p.fail("invalid Mermaid init directive: could not parse JSON/JSON5 config", .{});
            return true;
        }
        if (startsWith(t, "%%{")) {
            const lower = try util.lowerAscii(p.a, t);
            if (util.contains(lower, "init")) return p.fail("invalid Mermaid init directive syntax", .{});
        }
        return false;
    }

    fn looksLikeFlowchartEdgeSyntax(p: *Parser, line: []const u8) Error!bool {
        return p.arrow_token.isMatch(p.a, try maskBracketContent(p.a, line));
    }

    fn hasMissingFlowchartEdgeEndpoint(p: *Parser, line: []const u8) Error!bool {
        const masked = try maskBracketContent(p.a, line);
        const t = trim(masked);
        const ms = try p.arrow_token.findAll(p.a, t);
        for (ms) |m| {
            if (trim(t[0..m[0]]).len == 0 or trim(t[m[1]..]).len == 0) return true;
        }
        return false;
    }

    /// `preprocess_input`: trimmed, comment-stripped, non-empty lines.
    fn preprocessInput(p: *Parser, input: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var in_frontmatter = false;
        var it = util.lines(input);
        while (it.next()) |raw| {
            const t = trim(raw);
            if (t.len == 0) continue;
            if (eql(t, "---")) {
                in_frontmatter = !in_frontmatter;
                continue;
            }
            if (in_frontmatter) continue;
            if (try p.parseInitDirective(t)) continue;
            if (startsWith(t, "%%")) continue;
            const without = try stripTrailingComment(p.a, t);
            if (without.len == 0) continue;
            try out.append(p.a, without);
        }
        return out.items;
    }

    // ---------------------------------------------------------------------------------
    // Flowchart
    // ---------------------------------------------------------------------------------

    fn parseFlowchart(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .flowchart };
        var stack: std.ArrayList(usize) = .empty;
        const lines_ = try p.preprocessInput(input);
        for (lines_) |raw_line| {
            for (try splitStatements(a, raw_line)) |line| {
                if (line.len == 0) continue;
                if (try p.header.captures(a, line)) |caps| {
                    if (caps.get(2)) |m| if (ir.Direction.fromToken(m)) |dir| {
                        graph.direction = dir;
                    };
                    continue;
                }
                if (eql(line, "end")) {
                    _ = stack.pop();
                    continue;
                }
                if (try p.subgraph.captures(a, line)) |caps| {
                    const rest = caps.get(1) orelse "";
                    const h = try parseSubgraphHeader(a, rest);
                    try graph.subgraphs.append(a, .{ .id = h.id, .label = h.label });
                    try stack.append(a, graph.subgraphs.items.len - 1);
                    if (h.id) |id| try applySubgraphClasses(a, &graph, id, h.classes);
                    continue;
                }
                if (parseDirectionLine(line)) |direction| {
                    if (stack.items.len > 0) {
                        graph.subgraphs.items[stack.items[stack.items.len - 1]].direction = direction;
                    } else graph.direction = direction;
                    continue;
                }
                if (startsWith(line, "classDef")) {
                    try parseClassDef(a, line, &graph);
                    continue;
                }
                if (startsWith(line, "class ")) {
                    try parseClassLine(a, line, &graph);
                    continue;
                }
                if (startsWith(line, "style ")) {
                    try parseStyleLine(a, line, &graph);
                    continue;
                }
                if (startsWith(line, "linkStyle")) {
                    try parseLinkStyleLine(a, line, &graph);
                    continue;
                }
                if (try parseClickLine(a, line)) |click| {
                    try graph.node_links.put(a, click.id, click.link);
                    continue;
                }
                if (startsWith(line, "accTitle") or startsWith(line, "accDescr") or startsWith(line, "title ")) continue;
                if (try p.hasMissingFlowchartEdgeEndpoint(line)) return p.fail("invalid flowchart edge syntax: {s}", .{line});
                if (try p.splitEdgeChain(line)) |chain| {
                    var added = false;
                    for (chain) |edge_line| {
                        if (try p.addFlowchartEdge(edge_line, &graph, stack.items)) {
                            added = true;
                        } else if (try p.looksLikeFlowchartEdgeSyntax(edge_line)) {
                            return p.fail("invalid flowchart edge syntax: {s}", .{edge_line});
                        }
                    }
                    if (added) continue;
                }
                if (try p.addFlowchartEdge(line, &graph, stack.items)) continue;
                if (try p.looksLikeFlowchartEdgeSyntax(line)) return p.fail("invalid flowchart edge syntax: {s}", .{line});
                if (try parseNodeOnly(a, line)) |n| {
                    try graph.ensureNode(a, n.id, n.label, n.shape);
                    try applyNodeClasses(a, &graph, n.id, n.classes);
                    try addNodeToSubgraphs(a, &graph, stack.items, n.id);
                }
            }
        }
        return graph;
    }

    fn addFlowchartEdge(p: *Parser, line: []const u8, graph: *Graph, stack: []const usize) Error!bool {
        const a = p.a;
        const parsed = (try p.parseEdgeLine(line)) orelse return false;
        const sources = try splitOnAmpersand(a, parsed.left);
        const targets = try splitOnAmpersand(a, parsed.right);
        var source_ids: std.ArrayList([]const u8) = .empty;
        for (sources) |s| {
            const t = try parseNodeToken(a, s);
            try graph.ensureNode(a, t.id, t.label, t.shape);
            try applyNodeClasses(a, graph, t.id, t.classes);
            try addNodeToSubgraphs(a, graph, stack, t.id);
            try source_ids.append(a, t.id);
        }
        var target_ids: std.ArrayList([]const u8) = .empty;
        for (targets) |s| {
            const t = try parseNodeToken(a, s);
            try graph.ensureNode(a, t.id, t.label, t.shape);
            try applyNodeClasses(a, graph, t.id, t.classes);
            try addNodeToSubgraphs(a, graph, stack, t.id);
            try target_ids.append(a, t.id);
        }
        const m = parsed.meta;
        for (source_ids.items) |l| for (target_ids.items) |r| {
            try graph.edges.append(a, .{
                .from = l,
                .to = r,
                .label = parsed.label,
                .directed = m.directed,
                .arrow_start = m.arrow_start,
                .arrow_end = m.arrow_end,
                .arrow_start_kind = m.arrow_start_kind,
                .arrow_end_kind = m.arrow_end_kind,
                .start_decoration = m.start_decoration,
                .end_decoration = m.end_decoration,
                .style = m.style,
            });
        };
        return true;
    }

    fn splitEdgeChain(p: *Parser, line: []const u8) Error!?[]const []const u8 {
        const a = p.a;
        const masked = try maskBracketContent(a, line);
        if (try p.pipe_label.isMatch(a, masked) or try p.quoted_label.isMatch(a, line) or
            try p.label_arrow.isMatch(a, masked) or try p.compact_dotted.isMatch(a, masked)) return null;
        const ms = try p.arrow_token.findAll(a, masked);
        if (ms.len < 2) return null;
        var nodes: std.ArrayList([]const u8) = .empty;
        var arrows: std.ArrayList([]const u8) = .empty;
        var last: usize = 0;
        for (ms) |m| {
            try nodes.append(a, trim(line[last..m[0]]));
            try arrows.append(a, trim(line[m[0]..m[1]]));
            last = m[1];
        }
        try nodes.append(a, trim(line[last..]));
        if (nodes.items.len != arrows.items.len + 1) return null;
        var i: usize = 1;
        while (i < nodes.items.len) : (i += 1) {
            const t = util.trimStart(nodes.items[i]);
            if (t.len > 0 and t[0] == '|') {
                const stripped = t[1..];
                if (std.mem.indexOfScalar(u8, stripped, '|')) |end_idx| {
                    const label_len = end_idx + 2;
                    const label = t[0..label_len];
                    const rest = util.trimStart(t[label_len..]);
                    arrows.items[i - 1] = try util.concat(a, &.{ arrows.items[i - 1], label });
                    nodes.items[i] = rest;
                }
            }
        }
        for (nodes.items) |n| if (n.len == 0) return null;
        var out: std.ArrayList([]const u8) = .empty;
        for (arrows.items, 0..) |arrow, k| {
            try out.append(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ nodes.items[k], arrow, nodes.items[k + 1] }));
        }
        return out.items;
    }

    const EdgeLine = struct { left: []const u8, label: ?[]const u8, right: []const u8, meta: EdgeMeta };

    fn parseEdgeLine(p: *Parser, line: []const u8) Error!?EdgeLine {
        const a = p.a;
        const masked = try maskBracketContent(a, line);
        const extract = struct {
            fn f(l: []const u8, s: ?[2]usize) ?[]const u8 {
                const sp = s orelse return null;
                return l[sp[0]..sp[1]];
            }
        }.f;
        if (try p.pipe_label.captures(a, masked)) |caps| blk: {
            const left = trim(extract(line, caps.nameSpan("left")) orelse break :blk);
            const right = trim(extract(line, caps.nameSpan("right")) orelse break :blk);
            const label = trim(extract(line, caps.nameSpan("label")) orelse break :blk);
            const arrow_s = extract(line, caps.nameSpan("arrow")) orelse break :blk;
            if (label.len > 0 and left.len > 0 and right.len > 0) {
                return .{ .left = left, .label = label, .right = right, .meta = parseEdgeMeta(a, trim(arrow_s)) };
            }
        }
        if (try p.quoted_label.captures(a, line)) |caps| blk: {
            const left = trim(caps.named("left") orelse break :blk);
            const right = trim(caps.named("right") orelse break :blk);
            const label = trim(caps.named("label") orelse break :blk);
            if (label.len > 0 and left.len > 0 and right.len > 0) {
                const arrow = try util.concat(a, &.{ caps.named("start") orelse "", caps.named("dash1") orelse break :blk, caps.named("dash2") orelse break :blk, caps.named("end") orelse "" });
                return .{ .left = left, .label = label, .right = right, .meta = parseEdgeMeta(a, arrow) };
            }
        }
        if (try p.label_arrow.captures(a, masked)) |caps| blk: {
            const left = trim(extract(line, caps.nameSpan("left")) orelse break :blk);
            const right = trim(extract(line, caps.nameSpan("right")) orelse break :blk);
            const raw = trim(extract(line, caps.nameSpan("label")) orelse break :blk);
            const label = trim(util.trimMatches(raw, '|'));
            if (label.len > 0 and left.len > 0 and right.len > 0) {
                const arrow = try util.concat(a, &.{ caps.named("start") orelse "", caps.named("dash1") orelse break :blk, caps.named("dash2") orelse break :blk, caps.named("end") orelse "" });
                return .{ .left = left, .label = label, .right = right, .meta = parseEdgeMeta(a, arrow) };
            }
        }
        if (try p.compact_dotted.captures(a, masked)) |caps| blk: {
            const left = trim(extract(line, caps.nameSpan("left")) orelse break :blk);
            const right = trim(extract(line, caps.nameSpan("right")) orelse break :blk);
            const label = util.trimMatches(trim(extract(line, caps.nameSpan("label")) orelse break :blk), '.');
            if (label.len > 0 and left.len > 0 and right.len > 0) {
                const arrow = try util.concat(a, &.{ caps.named("start") orelse "", caps.named("dash1") orelse break :blk, ".", caps.named("dash2") orelse break :blk, caps.named("end") orelse "" });
                return .{ .left = left, .label = label, .right = right, .meta = parseEdgeMeta(a, arrow) };
            }
        }
        const caps = (try p.arrow.captures(a, masked)) orelse return null;
        const left = trim(extract(line, caps.nameSpan("left")) orelse return null);
        var arrow: []const u8 = trim(caps.named("arrow") orelse return null);
        var right: []const u8 = trim(extract(line, caps.nameSpan("right")) orelse return null);
        if (extractLeadingDecoration(right)) |dec| {
            arrow = try util.concat(a, &.{ arrow, &.{dec.ch} });
            right = dec.rest;
        }
        if (left.len == 0 or right.len == 0 or arrow.len == 0) return null;
        var label: ?[]const u8 = null;
        var right_token = right;
        if (right[0] == '|') {
            const stripped = right[1..];
            if (std.mem.indexOfScalar(u8, stripped, '|')) |end| {
                label = trim(stripped[0..end]);
                right_token = trim(stripped[end + 1 ..]);
            }
        }
        if (right_token.len == 0) return null;
        return .{ .left = left, .label = label, .right = right_token, .meta = parseEdgeMeta(a, arrow) };
    }

    // ---------------------------------------------------------------------------------
    // classDiagram
    // ---------------------------------------------------------------------------------

    fn parseClassDiagram(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .class, .direction = .top_down };
        var members: ir.StrMap(std.ArrayList([]const u8)) = .empty;
        var stereotypes: ir.StrMap(std.ArrayList([]const u8)) = .empty;
        var labels: ir.StrMap([]const u8) = .empty;
        var current_class: ?[]const u8 = null;
        for (try p.preprocessInput(input)) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;
            const lower = try util.lowerAscii(a, line);
            if (startsWith(lower, "classdiagram")) {
                const parts = try util.collectWhitespace(a, line);
                if (parts.len > 1) if (ir.Direction.fromToken(parts[1])) |dir| {
                    graph.direction = dir;
                };
                continue;
            }
            if (parseDirectionLine(line)) |dir| {
                graph.direction = dir;
                continue;
            }
            if (current_class) |active| {
                if (std.mem.indexOfScalar(u8, line, '}')) |end_idx| {
                    const fragment = trim(line[0..end_idx]);
                    if (fragment.len > 0) {
                        if (isClassStereotype(fragment)) try pushList(a, &stereotypes, active, fragment) else try pushList(a, &members, active, fragment);
                    }
                    current_class = null;
                } else if (isClassStereotype(trim(line))) {
                    try pushList(a, &stereotypes, active, trim(line));
                } else try pushList(a, &members, active, line);
                continue;
            }
            if (try parseClassRelationLine(a, line)) |rel| {
                const l = try normalizeClassId(a, rel.left);
                const r = try normalizeClassId(a, rel.right);
                if (l.label) |lab| try labels.put(a, l.id, lab);
                if (r.label) |lab| try labels.put(a, r.id, lab);
                try graph.ensureNode(a, l.id, labels.get(l.id), .rectangle);
                try graph.ensureNode(a, r.id, labels.get(r.id), .rectangle);
                const m = rel.meta;
                try graph.edges.append(a, .{
                    .from = l.id,
                    .to = r.id,
                    .label = rel.label,
                    .start_label = rel.start_label,
                    .end_label = rel.end_label,
                    .directed = m.directed,
                    .arrow_start = m.arrow_start,
                    .arrow_end = m.arrow_end,
                    .arrow_start_kind = m.arrow_start_kind,
                    .arrow_end_kind = m.arrow_end_kind,
                    .start_decoration = m.start_decoration,
                    .end_decoration = m.end_decoration,
                    .style = m.style,
                });
                continue;
            }
            if (startsWith(line, "class ")) {
                var rest = line;
                while (startsWith(rest, "class ")) rest = rest["class ".len..];
                rest = trim(rest);
                if (try parseClassDeclaration(a, rest)) |decl| {
                    if (decl.label) |lab| try labels.put(a, decl.id, lab);
                    try graph.ensureNode(a, decl.id, labels.get(decl.id), .rectangle);
                    if (decl.body) |body| {
                        for (try splitClassBody(a, body)) |entry| {
                            if (entry.len == 0) continue;
                            if (isClassStereotype(entry)) try pushList(a, &stereotypes, decl.id, entry) else try pushList(a, &members, decl.id, entry);
                        }
                    }
                    if (decl.open_body) current_class = decl.id;
                    continue;
                }
            }
            if (parseClassMemberLine(line)) |mem| {
                if (isClassStereotype(mem.member)) try pushList(a, &stereotypes, mem.id, mem.member) else try pushList(a, &members, mem.id, mem.member);
                continue;
            }
        }
        for (graph.nodes.values()) |*node| {
            const id = node.id;
            const class_name = labels.get(id) orelse node.label;
            var out: std.ArrayList([]const u8) = .empty;
            if (stereotypes.get(id)) |st| try out.appendSlice(a, st.items);
            try out.append(a, class_name);
            if (members.get(id)) |items| if (items.items.len > 0) {
                var attrs: std.ArrayList([]const u8) = .empty;
                var methods: std.ArrayList([]const u8) = .empty;
                for (items.items) |entry| {
                    const t = trim(entry);
                    if (util.containsChar(t, '(') and util.containsChar(t, ')')) {
                        try methods.append(a, try normalizeClassMethodSignature(a, t));
                    } else try attrs.append(a, t);
                }
                if (attrs.items.len > 0 or methods.items.len > 0) {
                    try out.append(a, "---");
                    if (attrs.items.len > 0) {
                        try out.appendSlice(a, attrs.items);
                        if (methods.items.len > 0) {
                            try out.append(a, "---");
                            try out.appendSlice(a, methods.items);
                        }
                    } else try out.appendSlice(a, methods.items);
                }
            };
            node.label = try util.join(a, out.items, "\n");
        }
        return graph;
    }

    // ---------------------------------------------------------------------------------
    // erDiagram
    // ---------------------------------------------------------------------------------

    fn parseErDiagram(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .er, .direction = .top_down };
        var members: ir.StrMap(std.ArrayList([]const u8)) = .empty;
        var current: ?[]const u8 = null;
        for (try p.preprocessInput(input)) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;
            const lower = try util.lowerAscii(a, line);
            if (startsWith(lower, "erdiagram")) continue;
            if (parseDirectionLine(line)) |dir| {
                graph.direction = dir;
                continue;
            }
            if (current) |active| {
                if (std.mem.indexOfScalar(u8, line, '}')) |end_idx| {
                    const fragment = trim(line[0..end_idx]);
                    if (fragment.len > 0) try pushList(a, &members, active, fragment);
                    current = null;
                } else try pushList(a, &members, active, line);
                continue;
            }
            if (try parseErRelationLine(a, line)) |rel| {
                try graph.ensureNode(a, rel.left, null, .round_rect);
                try graph.ensureNode(a, rel.right, null, .round_rect);
                try graph.edges.append(a, .{
                    .from = rel.left,
                    .to = rel.right,
                    .label = rel.label,
                    .start_decoration = rel.left_decoration,
                    .end_decoration = rel.right_decoration,
                    .style = rel.style,
                });
                continue;
            }
            if (std.mem.indexOfScalar(u8, line, '{')) |open_idx| {
                const name = try stripQuotes(a, trim(line[0..open_idx]));
                if (name.len > 0) {
                    try graph.ensureNode(a, name, null, .round_rect);
                    current = name;
                    const tail = trim(line[open_idx + 1 ..]);
                    if (std.mem.indexOfScalar(u8, tail, '}')) |close_idx| {
                        const fragment = trim(tail[0..close_idx]);
                        if (fragment.len > 0) try pushList(a, &members, name, fragment);
                        current = null;
                    } else if (tail.len > 0) try pushList(a, &members, name, tail);
                }
                continue;
            }
            const entity = try stripQuotes(a, line);
            if (entity.len > 0) try graph.ensureNode(a, entity, null, .round_rect);
        }
        for (graph.nodes.values()) |*node| {
            var out: std.ArrayList([]const u8) = .empty;
            try out.append(a, node.label);
            if (members.get(node.id)) |attrs| if (attrs.items.len > 0) {
                try out.append(a, "---");
                try out.appendSlice(a, attrs.items);
            };
            node.label = try util.join(a, out.items, "\n");
        }
        return graph;
    }

    // ---------------------------------------------------------------------------------
    // pie
    // ---------------------------------------------------------------------------------

    fn parsePieDiagram(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .pie };
        for (try p.preprocessInput(input)) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;
            const lower = try util.lowerAscii(a, line);
            if (startsWith(lower, "pie")) {
                if (util.contains(lower, "showdata")) graph.pie_show_data = true;
                if (util.find(lower, "title")) |title_pos| {
                    const title_start = title_pos + 5;
                    if (title_start <= line.len) {
                        const title = trim(line[title_start..]);
                        if (title.len > 0) graph.pie_title = title;
                    }
                }
                continue;
            }
            if (startsWith(lower, "showdata")) {
                graph.pie_show_data = true;
                continue;
            }
            if (startsWith(lower, "title")) {
                const title = if (line.len >= 5) trim(line[5..]) else "";
                if (title.len > 0) graph.pie_title = title;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const label = try stripQuotes(a, trim(line[0..colon]));
            if (label.len == 0) continue;
            const vs = trim(line[colon + 1 ..]);
            if (vs.len == 0) continue;
            const value = util.parseF32(vs) orelse continue;
            try graph.pie_slices.append(a, .{ .label = label, .value = value });
        }
        return graph;
    }

    // ---------------------------------------------------------------------------------
    // gantt
    // ---------------------------------------------------------------------------------

    fn parseGanttDiagram(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .gantt, .direction = .left_right };
        graph.gantt_display_mode = extractFrontmatterValue(input, "displayMode");
        var current_section: ?usize = null;
        var current_section_name: ?[]const u8 = null;
        var last_task: ?[]const u8 = null;
        for (try p.preprocessInput(input)) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;
            const lower = try util.lowerAscii(a, line);
            if (startsWith(lower, "gantt")) continue;
            if (startsWith(lower, "title")) {
                const title = if (line.len >= 5) trim(line[5..]) else "";
                if (title.len > 0) graph.gantt_title = title;
                continue;
            }
            const skip = [_][]const u8{ "dateformat", "axisformat", "tickinterval", "todaymarker", "excludes", "includes" };
            var skipped = false;
            for (skip) |k| skipped = skipped or startsWith(lower, k);
            if (skipped) continue;
            if (startsWith(lower, "section")) {
                const label = if (line.len >= 7) trim(line[7..]) else "";
                const id = try std.fmt.allocPrint(a, "section_{d}", .{graph.subgraphs.items.len});
                try graph.subgraphs.append(a, .{ .id = id, .label = label });
                current_section = graph.subgraphs.items.len - 1;
                current_section_name = label;
                try graph.gantt_sections.append(a, label);
                last_task = null;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const label = trim(line[0..colon]);
            if (label.len == 0) continue;
            const meta = try parseGanttTaskMeta(a, line[colon + 1 ..]);
            const node_id = meta.id orelse try std.fmt.allocPrint(a, "gantt_{d}", .{graph.nodes.len()});
            var node_label: []const u8 = label;
            if (meta.details.len > 0) node_label = try std.fmt.allocPrint(a, "{s}\n{s}", .{ label, try util.join(a, meta.details, " | ") });
            const timing = extractGanttTiming(meta.details);
            try graph.gantt_tasks.append(a, .{
                .id = node_id,
                .label = label,
                .start = timing.start,
                .duration = timing.duration,
                .after = meta.after,
                .section = current_section_name,
                .status = meta.status,
            });
            try graph.ensureNode(a, node_id, node_label, .rectangle);
            if (current_section) |idx| try graph.subgraphs.items[idx].nodes.append(a, node_id);
            if (meta.after) |after_id| {
                try graph.ensureNode(a, after_id, null, .rectangle);
                try graph.edges.append(a, .{ .from = after_id, .to = node_id, .directed = true, .arrow_end = true });
            } else if (last_task) |prev| {
                try graph.edges.append(a, .{ .from = prev, .to = node_id });
            }
            last_task = node_id;
        }
        return graph;
    }

    // ---------------------------------------------------------------------------------
    // stateDiagram
    // ---------------------------------------------------------------------------------

    const CompositeContext = struct {
        subgraph_idx: usize,
        regions: std.ArrayList(std.ArrayList([]const u8)),
        current_region: usize,
        has_separator: bool,
    };

    fn recordRegionNode(a: Allocator, stack: []CompositeContext, node_id: []const u8) Error!void {
        for (stack) |*ctx| {
            var seen = false;
            for (ctx.regions.items) |r| for (r.items) |id| {
                seen = seen or eql(id, node_id);
            };
            if (seen) continue;
            try ctx.regions.items[ctx.current_region].append(a, node_id);
        }
    }

    fn finalizeRegions(a: Allocator, ctx: CompositeContext, graph: *Graph, region_counter: *usize) Error!void {
        if (!ctx.has_separator) return;
        var regions: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        for (ctx.regions.items) |r| if (r.items.len > 0) try regions.append(a, r);
        if (regions.items.len <= 1) return;
        for (regions.items) |r| {
            const id = try std.fmt.allocPrint(a, "__region_{d}__", .{region_counter.*});
            region_counter.* += 1;
            try graph.subgraphs.append(a, .{ .id = id, .label = "", .nodes = r });
            try graph.subgraph_styles.put(a, id, .{ .fill = "none", .stroke = "none", .stroke_width = 0.0 });
        }
    }

    fn parseStateDiagram(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .state };
        var labels: ir.StrMap([]const u8) = .empty;
        var descriptions: ir.StrMap(std.ArrayList([]const u8)) = .empty;
        var start_states: ir.StrMap([]const u8) = .empty;
        var end_states: ir.StrMap([]const u8) = .empty;
        // Insertion order of the scope maps (Rust iterates HashMaps here, but the
        // result is order-independent: every qualifying id gets the same edit).
        var start_order: std.ArrayList([]const u8) = .empty;
        var end_order: std.ArrayList([]const u8) = .empty;
        var stack: std.ArrayList(usize) = .empty;
        var region_counter: usize = 0;
        var composite: std.ArrayList(CompositeContext) = .empty;
        var pending: std.ArrayList([]const u8) = .empty; // deque: front = end of list
        const lines_ = try p.preprocessInput(input);
        var li = lines_.len;
        while (li > 0) {
            li -= 1;
            try pending.append(a, lines_[li]);
        }
        while (pending.pop()) |raw_line| {
            for (try splitStatements(a, raw_line)) |raw_statement| {
                const raw = trim(raw_statement);
                if (raw.len == 0) continue;
                const st = try parseStateStereotype(a, raw);
                const line = trim(st.line);
                if (line.len == 0) continue;
                const lower = try util.lowerAscii(a, line);
                if (startsWith(lower, "statediagram")) continue;
                if (parseDirectionLine(line)) |dir| {
                    graph.direction = dir;
                    continue;
                }
                if (startsWith(line, "classDef")) {
                    try parseClassDef(a, line, &graph);
                    continue;
                }
                if (startsWith(line, "class ")) {
                    try parseClassLine(a, line, &graph);
                    continue;
                }
                if (startsWith(line, "style ")) {
                    try parseStyleLine(a, line, &graph);
                    continue;
                }
                if (eql(line, "}")) {
                    if (composite.pop()) |ctx| {
                        if (stack.pop()) |idx| if (idx != ctx.subgraph_idx) try stack.append(a, idx);
                        try finalizeRegions(a, ctx, &graph, &region_counter);
                    }
                    continue;
                }
                if (eql(line, "--")) {
                    if (composite.items.len > 0) {
                        const ctx = &composite.items[composite.items.len - 1];
                        ctx.has_separator = true;
                        try ctx.regions.append(a, .empty);
                        ctx.current_region = ctx.regions.items.len -| 1;
                    }
                    continue;
                }
                if (try parseStateContainerHeader(a, line)) |h| {
                    if (h.id) |id| try labels.put(a, id, h.label);
                    try graph.subgraphs.append(a, .{ .id = h.id, .label = h.label });
                    try stack.append(a, graph.subgraphs.items.len - 1);
                    var regions: std.ArrayList(std.ArrayList([]const u8)) = .empty;
                    try regions.append(a, .empty);
                    try composite.append(a, .{ .subgraph_idx = graph.subgraphs.items.len - 1, .regions = regions, .current_region = 0, .has_separator = false });
                    if (h.tail.len > 0) {
                        if (std.mem.indexOfScalar(u8, h.tail, '}')) |close_idx| {
                            const body = trim(h.tail[0..close_idx]);
                            const after = trim(h.tail[close_idx + 1 ..]);
                            if (after.len > 0) try pending.append(a, after);
                            try pending.append(a, "}");
                            if (body.len > 0) try pending.append(a, body);
                        } else try pending.append(a, h.tail);
                    }
                    continue;
                }
                if (try parseStateAliasLine(a, line)) |al| {
                    const label = st.label_override orelse al.label;
                    try labels.put(a, al.id, label);
                    try graph.ensureNode(a, al.id, try stateDisplayLabel(a, al.id, &labels, &descriptions), st.shape orelse .round_rect);
                    try applyNodeClasses(a, &graph, al.id, al.classes);
                    try addNodeToSubgraphs(a, &graph, stack.items, al.id);
                    try recordRegionNode(a, composite.items, al.id);
                    continue;
                }
                if (try parseStateTransition(a, line)) |tr| {
                    const scope: []const u8 = blk: {
                        if (stack.items.len == 0) break :blk "root";
                        const sub = graph.subgraphs.items[stack.items[stack.items.len - 1]];
                        break :blk sub.id orelse "root";
                    };
                    const lt = try splitInlineClasses(a, tr.left);
                    const rt = try splitInlineClasses(a, tr.right);
                    const ln = try normalizeStateToken(a, lt.base, true, &start_states, &end_states, &start_order, &end_order, scope);
                    const rn = try normalizeStateToken(a, rt.base, false, &start_states, &end_states, &start_order, &end_order, scope);
                    const left_label = ln.label_override orelse try stateDisplayLabelOption(a, ln.id, &labels, &descriptions);
                    const right_label = rn.label_override orelse try stateDisplayLabelOption(a, rn.id, &labels, &descriptions);
                    const left_shape: ?NodeShape = if (ln.shape == .round_rect and graph.nodes.contains(ln.id)) null else ln.shape;
                    const right_shape: ?NodeShape = if (rn.shape == .round_rect and graph.nodes.contains(rn.id)) null else rn.shape;
                    try graph.ensureNode(a, ln.id, left_label, left_shape);
                    try graph.ensureNode(a, rn.id, right_label, right_shape);
                    try applyNodeClasses(a, &graph, ln.id, lt.classes);
                    try applyNodeClasses(a, &graph, rn.id, rt.classes);
                    try addNodeToSubgraphs(a, &graph, stack.items, ln.id);
                    try addNodeToSubgraphs(a, &graph, stack.items, rn.id);
                    try recordRegionNode(a, composite.items, ln.id);
                    try recordRegionNode(a, composite.items, rn.id);
                    const m = tr.meta;
                    try graph.edges.append(a, .{
                        .from = ln.id,
                        .to = rn.id,
                        .label = tr.label,
                        .directed = m.directed,
                        .arrow_start = m.arrow_start,
                        .arrow_end = m.arrow_end,
                        .style = m.style,
                    });
                    continue;
                }
                if (try parseStateDescriptionLine(a, line)) |d| {
                    const label = st.label_override orelse d.desc;
                    try pushList(a, &descriptions, d.id, label);
                    try graph.ensureNode(a, d.id, try stateDisplayLabel(a, d.id, &labels, &descriptions), st.shape orelse .round_rect);
                    try applyNodeClasses(a, &graph, d.id, d.classes);
                    try addNodeToSubgraphs(a, &graph, stack.items, d.id);
                    try recordRegionNode(a, composite.items, d.id);
                    continue;
                }
                if (try parseStateNote(a, line)) |n| {
                    const t = try splitInlineClasses(a, n.target);
                    const target = try stripQuotes(a, trim(t.base));
                    if (target.len == 0) continue;
                    const shape: ?NodeShape = if (graph.nodes.contains(target)) null else .round_rect;
                    try graph.ensureNode(a, target, try stateDisplayLabelOption(a, target, &labels, &descriptions), shape);
                    try applyNodeClasses(a, &graph, target, t.classes);
                    try graph.state_notes.append(a, .{ .position = n.position, .target = target, .label = n.label });
                    try addNodeToSubgraphs(a, &graph, stack.items, target);
                    try recordRegionNode(a, composite.items, target);
                    continue;
                }
                if (try parseStateSimple(a, line)) |s| {
                    if (st.label_override) |lab| try labels.put(a, s.id, lab);
                    try graph.ensureNode(a, s.id, try stateDisplayLabelOption(a, s.id, &labels, &descriptions), st.shape orelse .round_rect);
                    try applyNodeClasses(a, &graph, s.id, s.classes);
                    try addNodeToSubgraphs(a, &graph, stack.items, s.id);
                    try recordRegionNode(a, composite.items, s.id);
                    continue;
                }
            }
        }
        // Scoped [*] fan-out / fan-in nodes become fork/join bars.
        var outgoing: ir.StrMap(usize) = .empty;
        var incoming: ir.StrMap(usize) = .empty;
        for (graph.edges.items) |e| {
            const o = try outgoing.getOrPut(a, e.from);
            o.value_ptr.* = (if (o.found_existing) o.value_ptr.* else 0) + 1;
            const in_ = try incoming.getOrPut(a, e.to);
            in_.value_ptr.* = (if (in_.found_existing) in_.value_ptr.* else 0) + 1;
        }
        for (start_order.items) |scope| {
            if (eql(scope, "root")) continue;
            const id = start_states.get(scope).?;
            if ((outgoing.get(id) orelse 0) > 1) if (graph.nodes.get(id)) |node| {
                node.shape = .fork_join;
                node.label = "";
            };
        }
        for (end_order.items) |scope| {
            if (eql(scope, "root")) continue;
            const id = end_states.get(scope).?;
            if ((incoming.get(id) orelse 0) > 1) if (graph.nodes.get(id)) |node| {
                node.shape = .fork_join;
                node.label = "";
            };
        }
        return graph;
    }

    // ---------------------------------------------------------------------------------
    // sequenceDiagram
    // ---------------------------------------------------------------------------------

    fn parseSequenceDiagram(p: *Parser, input: []const u8) Error!Graph {
        const a = p.a;
        var graph: Graph = .{ .kind = .sequence, .direction = .left_right };
        var labels: ir.StrMap([]const u8) = .empty;
        var order: std.ArrayList([]const u8) = .empty;
        var open_frames: std.ArrayList(OpenFrame) = .empty;
        var frames: std.ArrayList(ir.SequenceFrame) = .empty;
        var open_boxes: std.ArrayList(ir.SequenceBox) = .empty;
        for (try p.preprocessInput(input)) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;
            const lower = try util.lowerAscii(a, line);
            if (startsWith(lower, "sequencediagram")) continue;
            if (try parseSequenceParticipant(a, line)) |part| {
                if (!containsStr(order.items, part.id)) try order.append(a, part.id);
                if (part.label) |lab| try labels.put(a, part.id, lab);
                try ensureSequenceNode(a, &graph, &labels, part.id, part.shape);
                if (open_boxes.items.len > 0) {
                    const bx = &open_boxes.items[open_boxes.items.len - 1];
                    if (!containsStr(bx.participants.items, part.id)) try bx.participants.append(a, part.id);
                }
                continue;
            }
            if (try parseSequenceBoxLine(a, line)) |bx| {
                try open_boxes.append(a, .{ .label = bx.label, .color = bx.color });
                continue;
            }
            const frame_kw = [_][]const u8{ "alt", "opt", "loop", "par", "rect", "critical", "break" };
            var is_frame = false;
            for (frame_kw) |kw| is_frame = is_frame or eql(lower, kw) or (startsWith(lower, kw) and lower.len > kw.len and lower[kw.len] == ' ');
            if (is_frame) {
                var kind: ir.SequenceFrameKind = .alt;
                var offset: usize = 3;
                if (startsWith(lower, "opt")) {
                    kind = .opt;
                    offset = 3;
                } else if (startsWith(lower, "loop")) {
                    kind = .loop;
                    offset = 4;
                } else if (startsWith(lower, "par")) {
                    kind = .par;
                    offset = 3;
                } else if (startsWith(lower, "rect")) {
                    kind = .rect;
                    offset = 4;
                } else if (startsWith(lower, "critical")) {
                    kind = .critical;
                    offset = 8;
                } else if (startsWith(lower, "break")) {
                    kind = .@"break";
                    offset = 5;
                }
                const lab = trim(if (offset <= line.len) line[offset..] else "");
                const label: ?[]const u8 = if (lab.len == 0) null else try stripQuotes(a, lab);
                const start_idx = graph.edges.items.len;
                var sections: std.ArrayList(ir.SequenceFrameSection) = .empty;
                try sections.append(a, .{ .label = label, .start_idx = start_idx, .end_idx = start_idx });
                try open_frames.append(a, .{ .kind = kind, .sections = sections, .start_idx = start_idx });
                continue;
            }
            if (eql(lower, "else") or startsWith(lower, "else ")) {
                if (open_frames.items.len > 0) try splitFrame(a, &open_frames.items[open_frames.items.len - 1], graph.edges.items.len, line, 4);
                continue;
            }
            if (eql(lower, "and") or startsWith(lower, "and ")) {
                if (open_frames.items.len > 0 and open_frames.items[open_frames.items.len - 1].kind == .par) try splitFrame(a, &open_frames.items[open_frames.items.len - 1], graph.edges.items.len, line, 3);
                continue;
            }
            if (eql(lower, "option") or startsWith(lower, "option ")) {
                if (open_frames.items.len > 0 and open_frames.items[open_frames.items.len - 1].kind == .critical) try splitFrame(a, &open_frames.items[open_frames.items.len - 1], graph.edges.items.len, line, 6);
                continue;
            }
            if (eql(lower, "end")) {
                if (open_frames.pop()) |f| {
                    try frames.append(a, try f.close(a, graph.edges.items.len));
                } else if (open_boxes.pop()) |bx| try graph.sequence_boxes.append(a, bx);
                continue;
            }
            if (try parseSequenceNote(a, line)) |n| {
                for (n.participants) |id| {
                    if (!containsStr(order.items, id)) try order.append(a, id);
                    try ensureSequenceNode(a, &graph, &labels, id, null);
                }
                try graph.sequence_notes.append(a, .{ .position = n.position, .participants = n.participants, .label = n.label, .index = graph.edges.items.len });
                continue;
            }
            if (startsWith(lower, "activate ") or startsWith(lower, "deactivate ")) {
                const deact = startsWith(lower, "deactivate ");
                const raw_id = trim(line[if (deact) 11 else 9 ..]);
                if (raw_id.len > 0) {
                    const id = try stripQuotes(a, raw_id);
                    if (!containsStr(order.items, id)) try order.append(a, id);
                    try ensureSequenceNode(a, &graph, &labels, id, null);
                    try graph.sequence_activations.append(a, .{ .participant = id, .index = graph.edges.items.len, .kind = if (deact) .deactivate else .activate });
                }
                continue;
            }
            if (startsWith(lower, "autonumber")) {
                const parts = try util.collectWhitespace(a, line);
                if (parts.len >= 2) {
                    const token = try util.lowerAscii(a, parts[1]);
                    if (eql(token, "off") or eql(token, "stop") or eql(token, "disable")) {
                        graph.sequence_autonumber = null;
                    } else if (util.parseUsize(parts[1])) |start| {
                        graph.sequence_autonumber = start;
                    } else graph.sequence_autonumber = 1;
                } else graph.sequence_autonumber = 1;
                continue;
            }
            if (try parseSequenceMessage(a, line)) |msg| {
                if (!containsStr(order.items, msg.from)) try order.append(a, msg.from);
                if (!containsStr(order.items, msg.to)) try order.append(a, msg.to);
                try ensureSequenceNode(a, &graph, &labels, msg.from, null);
                try ensureSequenceNode(a, &graph, &labels, msg.to, null);
                try graph.edges.append(a, .{ .from = msg.from, .to = msg.to, .label = msg.label, .directed = true, .arrow_end = true, .style = msg.style });
                if (msg.activation) |kind| {
                    const last = graph.edges.items.len - 1;
                    try graph.sequence_activations.append(a, .{ .participant = graph.edges.items[last].to, .index = last, .kind = kind });
                }
            }
        }
        while (open_frames.pop()) |f| try frames.append(a, try f.close(a, graph.edges.items.len));
        while (open_boxes.pop()) |bx| try graph.sequence_boxes.append(a, bx);
        graph.sequence_participants = order;
        graph.sequence_frames = frames;
        return graph;
    }

    const OpenFrame = struct {
        kind: ir.SequenceFrameKind,
        sections: std.ArrayList(ir.SequenceFrameSection),
        start_idx: usize,

        fn close(f: OpenFrame, a: Allocator, end_idx: usize) Error!ir.SequenceFrame {
            _ = a;
            var s = f.sections;
            if (s.items.len > 0) s.items[s.items.len - 1].end_idx = end_idx;
            return .{ .kind = f.kind, .sections = s.items, .start_idx = f.start_idx, .end_idx = end_idx };
        }
    };

    fn splitFrame(a: Allocator, frame: *OpenFrame, split_idx: usize, line: []const u8, offset: usize) Error!void {
        if (frame.sections.items.len > 0) frame.sections.items[frame.sections.items.len - 1].end_idx = split_idx;
        const lab = trim(if (offset <= line.len) line[offset..] else "");
        const label: ?[]const u8 = if (lab.len == 0) null else try stripQuotes(a, lab);
        try frame.sections.append(a, .{ .label = label, .start_idx = split_idx, .end_idx = split_idx });
    }
};

// ---------------------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------------------

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (eql(x, s)) return true;
    return false;
}

fn pushList(a: Allocator, map: *ir.StrMap(std.ArrayList([]const u8)), key: []const u8, value: []const u8) Allocator.Error!void {
    const gop = try map.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, value);
}

const EdgeMeta = struct {
    directed: bool = false,
    arrow_start: bool = false,
    arrow_end: bool = false,
    arrow_start_kind: ?ir.EdgeArrowhead = null,
    arrow_end_kind: ?ir.EdgeArrowhead = null,
    start_decoration: ?ir.EdgeDecoration = null,
    end_decoration: ?ir.EdgeDecoration = null,
    style: ir.EdgeStyle = .solid,
};

fn parseEdgeMeta(a: Allocator, arrow: []const u8) EdgeMeta {
    _ = a;
    var t = trim(arrow);
    var m: EdgeMeta = .{};
    if (t.len > 0 and t[0] == 'o') {
        m.start_decoration = .circle;
        t = t[1..];
    } else if (t.len > 0 and t[0] == 'x') {
        m.start_decoration = .cross;
        t = t[1..];
    }
    if (t.len > 0 and t[t.len - 1] == 'o') {
        m.end_decoration = .circle;
        t = t[0 .. t.len - 1];
    } else if (t.len > 0 and t[t.len - 1] == 'x') {
        m.end_decoration = .cross;
        t = t[0 .. t.len - 1];
    }
    m.arrow_start = t.len > 0 and t[0] == '<';
    m.arrow_end = t.len > 0 and t[t.len - 1] == '>';
    m.style = if (util.containsChar(t, '=')) .thick else if (util.containsChar(t, '.')) .dotted else .solid;
    m.directed = m.arrow_start or m.arrow_end;
    return m;
}

fn extractLeadingDecoration(right: []const u8) ?struct { ch: u8, rest: []const u8 } {
    if (right.len == 0) return null;
    const first = right[0];
    if (first != 'o' and first != 'x') return null;
    const rest = right[1..];
    if (rest.len == 0) return null;
    if (util.isWhitespace(util.decodeAt(rest, 0).cp)) return .{ .ch = first, .rest = util.trimStart(rest) };
    return null;
}

pub fn splitStatements(a: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var depth: i32 = 0;
    var quote: ?u21 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) {
        const d = util.decodeAt(line, i);
        const ch = d.cp;
        const bytes = line[i .. i + d.len];
        i += d.len;
        if (escaped) {
            try current.appendSlice(a, bytes);
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            try current.appendSlice(a, bytes);
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (ch == q) quote = null;
            try current.appendSlice(a, bytes);
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            try current.appendSlice(a, bytes);
            continue;
        }
        switch (ch) {
            '[', '(', '{' => {
                depth += 1;
                try current.appendSlice(a, bytes);
            },
            ']', ')', '}' => {
                if (depth > 0) depth -= 1;
                try current.appendSlice(a, bytes);
            },
            ';' => if (depth == 0) {
                const t = trim(current.items);
                if (t.len > 0) try parts.append(a, try a.dupe(u8, t));
                current = .empty;
            } else try current.appendSlice(a, bytes),
            else => try current.appendSlice(a, bytes),
        }
    }
    const t = trim(current.items);
    if (t.len > 0) try parts.append(a, t);
    return parts.items;
}

pub fn stripTrailingComment(a: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '%' and i + 1 < line.len and line[i + 1] == '%') break;
    }
    _ = a;
    return trim(line[0..i]);
}

const SubgraphHeader = struct { id: ?[]const u8, label: []const u8, classes: []const []const u8 };

fn parseSubgraphHeader(a: Allocator, input: []const u8) Allocator.Error!SubgraphHeader {
    const sc = try splitInlineClasses(a, input);
    const t = trim(sc.base);
    if (t.len == 0) return .{ .id = null, .label = "Subgraph", .classes = sc.classes };
    if (try splitIdLabel(a, t)) |il| return .{ .id = il.id, .label = il.label, .classes = sc.classes };
    if (!util.containsChar(t, '"') and !util.containsChar(t, '\'')) {
        const parts = try util.collectWhitespace(a, t);
        if (parts.len == 1) return .{ .id = parts[0], .label = parts[0], .classes = sc.classes };
    }
    return .{ .id = null, .label = try stripQuotes(a, t), .classes = sc.classes };
}

const NodeToken = struct { id: []const u8, label: ?[]const u8, shape: ?NodeShape, classes: []const []const u8 };

fn parseNodeOnly(a: Allocator, line: []const u8) Allocator.Error!?NodeToken {
    if (util.contains(line, "--")) return null;
    const t = try parseNodeToken(a, line);
    if (t.id.len == 0) return null;
    return t;
}

/// Characters inside `[...]`, `(...)`, `{...}` and quotes become spaces (byte length kept).
pub fn maskBracketContent(a: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var sq: i32 = 0;
    var par: i32 = 0;
    var cur: i32 = 0;
    var dq = false;
    var sqt = false;
    var prev: u21 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const d = util.decodeAt(line, i);
        const ch = d.cp;
        const bytes = line[i .. i + d.len];
        i += d.len;
        const in_bracket = sq > 0 or par > 0 or cur > 0;
        const in_quote = dq or sqt;
        const spaces = struct {
            fn f(al: Allocator, o: *std.ArrayList(u8), n: usize) Allocator.Error!void {
                var k: usize = 0;
                while (k < n) : (k += 1) try o.append(al, ' ');
            }
        }.f;
        if (ch == '[' and !in_quote) {
            sq += 1;
            try out.appendSlice(a, bytes);
        } else if (ch == ']' and !in_quote and sq > 0) {
            sq -= 1;
            try out.appendSlice(a, bytes);
        } else if (ch == '(' and !in_quote and !in_bracket) {
            par += 1;
            try out.appendSlice(a, bytes);
        } else if (ch == ')' and !in_quote and par > 0) {
            par -= 1;
            try out.appendSlice(a, bytes);
        } else if (ch == '{' and !in_quote and !in_bracket) {
            cur += 1;
            try out.appendSlice(a, bytes);
        } else if (ch == '}' and !in_quote and cur > 0) {
            cur -= 1;
            try out.appendSlice(a, bytes);
        } else if (ch == '"' and prev != '\\') {
            dq = !dq;
            if (in_bracket or in_quote) try spaces(a, &out, d.len) else try out.appendSlice(a, bytes);
        } else if (ch == '\'' and prev != '\\') {
            sqt = !sqt;
            if (in_bracket or in_quote) try spaces(a, &out, d.len) else try out.appendSlice(a, bytes);
        } else {
            if (in_bracket or in_quote) try spaces(a, &out, d.len) else try out.appendSlice(a, bytes);
        }
        prev = ch;
    }
    return out.items;
}

fn splitOnAmpersand(a: Allocator, input: []const u8) Allocator.Error![]const []const u8 {
    const masked = try maskBracketContent(a, input);
    var parts: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (masked, 0..) |c, i| {
        if (c == '&') {
            const part = trim(input[start..i]);
            if (part.len > 0) try parts.append(a, part);
            start = i + 1;
        }
    }
    const last = trim(input[start..]);
    if (last.len > 0) try parts.append(a, last);
    return parts.items;
}

pub fn parseDirectionLine(line: []const u8) ?ir.Direction {
    var it = util.splitWhitespace(line);
    const first = it.next() orelse return null;
    const second = it.next() orelse return null;
    if (it.next() != null) return null;
    if (!eql(first, "direction")) return null;
    return ir.Direction.fromToken(second);
}

fn splitN(s: []const u8, n: usize, comptime isSep: fn (u21) bool) [3][]const u8 {
    // `splitn(3, pred)`: up to three parts; missing parts are "".
    var out: [3][]const u8 = .{ "", "", "" };
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var have = false;
    while (i < s.len and count + 1 < n) {
        const d = util.decodeAt(s, i);
        if (isSep(d.cp)) {
            out[count] = s[start..i];
            count += 1;
            start = i + d.len;
        }
        i += d.len;
    }
    out[count] = s[start..];
    have = true;
    _ = &have;
    return out;
}

fn isWs(cp: u21) bool {
    return util.isWhitespace(cp);
}

fn isSpace(cp: u21) bool {
    return cp == ' ';
}

fn parseClassDef(a: Allocator, line: []const u8, graph: *Graph) Allocator.Error!void {
    const t = trim(line);
    const parts = splitN(t, 3, isWs);
    const class_name = trim(parts[1]);
    const rest = trim(parts[2]);
    if (class_name.len == 0 or rest.len == 0) return;
    try graph.class_defs.put(a, class_name, parseNodeStyle(rest));
}

fn parseClassLine(a: Allocator, line: []const u8, graph: *Graph) Allocator.Error!void {
    const parts = try util.collectWhitespace(a, line);
    if (parts.len < 3) return;
    var class_names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, parts[parts.len - 1], ',');
    while (it.next()) |n| {
        const t = trim(n);
        if (t.len > 0) try class_names.append(a, t);
    }
    if (class_names.items.len == 0) return;
    const nodes_raw = try util.join(a, parts[1 .. parts.len - 1], " ");
    var nit = std.mem.splitScalar(u8, nodes_raw, ',');
    while (nit.next()) |raw| {
        const id = trim(raw);
        if (id.len == 0) continue;
        for (class_names.items) |cn| {
            try pushList(a, &graph.node_classes, id, cn);
            try pushList(a, &graph.subgraph_classes, id, cn);
        }
    }
}

fn applyNodeClasses(a: Allocator, graph: *Graph, node_id: []const u8, classes: []const []const u8) Allocator.Error!void {
    for (classes) |c| {
        if (c.len == 0) continue;
        try pushList(a, &graph.node_classes, node_id, c);
    }
}

fn applySubgraphClasses(a: Allocator, graph: *Graph, id: []const u8, classes: []const []const u8) Allocator.Error!void {
    for (classes) |c| {
        if (c.len == 0) continue;
        try pushList(a, &graph.subgraph_classes, id, c);
    }
}

fn parseStyleLine(a: Allocator, line: []const u8, graph: *Graph) Allocator.Error!void {
    const parts = splitN(line, 3, isSpace);
    const node_id = trim(parts[1]);
    const rest = trim(parts[2]);
    if (node_id.len == 0 or rest.len == 0) return;
    const style = parseNodeStyle(rest);
    var it = std.mem.splitScalar(u8, node_id, ',');
    while (it.next()) |raw| {
        const id = trim(raw);
        if (id.len == 0) continue;
        try graph.node_styles.put(a, id, style);
        try graph.subgraph_styles.put(a, id, style);
    }
}

fn parseLinkStyleLine(a: Allocator, line: []const u8, graph: *Graph) Allocator.Error!void {
    const tokens = try util.collectWhitespace(a, trim(line));
    if (tokens.len < 3) return;
    var style_idx: ?usize = null;
    for (tokens[1..], 1..) |tok, i| if (util.containsChar(tok, ':')) {
        style_idx = i;
        break;
    };
    const si = style_idx orelse return;
    const index_tokens = tokens[1..si];
    const style_str = try util.join(a, tokens[si..], " ");
    if (style_str.len == 0) return;
    const style = parseEdgeStyle(style_str);
    if (index_tokens.len == 1 and eql(index_tokens[0], "default")) {
        graph.edge_style_default = style;
        return;
    }
    for (index_tokens) |tok| {
        var it = std.mem.splitScalar(u8, tok, ',');
        while (it.next()) |raw| {
            const t = trim(raw);
            if (t.len == 0) continue;
            if (util.parseUsize(t)) |index| try graph.edge_styles.put(a, index, style);
        }
    }
}

fn tokenizeQuoted(a: Allocator, input: []const u8) Allocator.Error![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var quote: ?u21 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < input.len) {
        const d = util.decodeAt(input, i);
        const bytes = input[i .. i + d.len];
        i += d.len;
        const ch = d.cp;
        if (escaped) {
            try current.appendSlice(a, bytes);
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (ch == q) quote = null else try current.appendSlice(a, bytes);
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (util.isWhitespace(ch)) {
            if (current.items.len > 0) {
                try tokens.append(a, current.items);
                current = .empty;
            }
            continue;
        }
        try current.appendSlice(a, bytes);
    }
    if (current.items.len > 0) try tokens.append(a, current.items);
    return tokens.items;
}

fn parseClickLine(a: Allocator, line: []const u8) Allocator.Error!?struct { id: []const u8, link: ir.NodeLink } {
    const t = trim(line);
    const lower = try util.lowerAscii(a, t);
    const kw: usize = if (startsWith(lower, "click ")) 5 else if (startsWith(lower, "link ")) 4 else return null;
    const rest = trim(t[kw..]);
    const tokens = try tokenizeQuoted(a, rest);
    if (tokens.len < 2) return null;
    const id = tokens[0];
    var idx: usize = 1;
    if (std.ascii.eqlIgnoreCase(tokens[idx], "call")) return null;
    if (std.ascii.eqlIgnoreCase(tokens[idx], "href")) idx += 1;
    if (idx >= tokens.len) return null;
    const url = tokens[idx];
    idx += 1;
    var title: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    if (idx < tokens.len) {
        if (startsWith(tokens[idx], "_")) target = tokens[idx] else title = tokens[idx];
        idx += 1;
    }
    if (target == null and idx < tokens.len and startsWith(tokens[idx], "_")) target = tokens[idx];
    return .{ .id = id, .link = .{ .url = url, .title = title, .target = target } };
}

fn splitKv(part: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, part, ':')) |i| return .{ trim(part[0..i]), trim(part[i + 1 ..]) };
    return .{ trim(part), "" };
}

pub fn parseNodeStyle(input: []const u8) ir.NodeStyle {
    var style: ir.NodeStyle = .{};
    var it = std.mem.splitScalar(u8, input, ',');
    while (it.next()) |part| {
        const kv = splitKv(part);
        const key = kv[0];
        const value = kv[1];
        if (key.len == 0 or value.len == 0) continue;
        if (eql(key, "fill")) style.fill = value else if (eql(key, "stroke")) style.stroke = value else if (eql(key, "stroke-width")) {
            style.stroke_width = util.parseF32(std.mem.trimEnd(u8, value, "px"));
        } else if (eql(key, "stroke-dasharray")) style.stroke_dasharray = value else if (eql(key, "color")) style.text_color = value;
    }
    return style;
}

fn trimEndMatchesPx(v: []const u8) []const u8 {
    var s = v;
    while (endsWith(s, "px")) s = s[0 .. s.len - 2];
    return s;
}

fn parseEdgeStyle(input: []const u8) ir.EdgeStyleOverride {
    var style: ir.EdgeStyleOverride = .{};
    var it = std.mem.splitScalar(u8, input, ',');
    while (it.next()) |part| {
        const kv = splitKv(part);
        const key = kv[0];
        const value = kv[1];
        if (key.len == 0 or value.len == 0) continue;
        if (eql(key, "stroke")) style.stroke = value else if (eql(key, "stroke-width")) {
            style.stroke_width = util.parseF32(trimEndMatchesPx(value));
        } else if (eql(key, "stroke-dasharray")) style.dasharray = value else if (eql(key, "color")) style.label_color = value;
    }
    return style;
}

fn parseNodeToken(a: Allocator, token: []const u8) Allocator.Error!NodeToken {
    const sc = try splitInlineClasses(a, token);
    const t = trim(sc.base);
    if (try splitAsymmetricLabel(a, t)) |r| return .{ .id = r.id, .label = r.label, .shape = .asymmetric, .classes = sc.classes };
    if (try splitIdLabel(a, t)) |r| return .{ .id = r.id, .label = r.label, .shape = r.shape, .classes = sc.classes };
    var it = util.splitWhitespace(t);
    return .{ .id = it.next() orelse "", .label = null, .shape = null, .classes = sc.classes };
}

fn splitAsymmetricLabel(a: Allocator, token: []const u8) Allocator.Error!?struct { id: []const u8, label: []const u8 } {
    const t = trim(token);
    if (util.containsChar(t, '[')) return null;
    const pos = std.mem.indexOfScalar(u8, t, '>') orelse return null;
    if (!endsWith(t, "]")) return null;
    const id = trim(t[0..pos]);
    if (id.len == 0) return null;
    if (pos + 1 > t.len - 1) return null;
    const label = trim(t[pos + 1 .. t.len - 1]);
    if (label.len == 0) return null;
    return .{ .id = id, .label = try stripQuotes(a, label) };
}

fn splitInlineClasses(a: Allocator, token: []const u8) Allocator.Error!struct { base: []const u8, classes: []const []const u8 } {
    var it = std.mem.splitSequence(u8, token, ":::");
    const base = trim(it.next() orelse "");
    var classes: std.ArrayList([]const u8) = .empty;
    while (it.next()) |part| {
        const t = trim(part);
        if (t.len > 0) try classes.append(a, t);
    }
    return .{ .base = base, .classes = classes.items };
}

fn splitIdLabel(a: Allocator, token: []const u8) Allocator.Error!?struct { id: []const u8, label: []const u8, shape: NodeShape } {
    if (std.mem.indexOfScalar(u8, token, '[')) |start| if (endsWith(token, "]")) {
        const id = trim(token[0..start]);
        if (id.len > 0) {
            const r = try parseShapeFromBrackets(a, token[start..]);
            return .{ .id = id, .label = r.label, .shape = r.shape };
        }
    };
    if (std.mem.indexOfScalar(u8, token, '(')) |start| if (endsWith(token, ")")) {
        const id = trim(token[0..start]);
        if (id.len > 0) {
            const r = try parseShapeFromParens(a, token[start..]);
            return .{ .id = id, .label = r.label, .shape = r.shape };
        }
    };
    if (std.mem.indexOfScalar(u8, token, '{')) |start| if (endsWith(token, "}")) {
        const id = trim(token[0..start]);
        if (id.len > 0) {
            const r = try parseShapeFromBraces(a, token[start..]);
            return .{ .id = id, .label = r.label, .shape = r.shape };
        }
    };
    return null;
}

const LabelShape = struct { label: []const u8, shape: NodeShape };

fn inner2(t: []const u8, n: usize) []const u8 {
    if (t.len < 2 * n) return "";
    return t[n .. t.len - n];
}

fn parseShapeFromBrackets(a: Allocator, raw: []const u8) Allocator.Error!LabelShape {
    const t = trim(raw);
    if (t.len >= 4) {
        if (startsWith(t, "[/") and endsWith(t, "/]")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .parallelogram };
        if (startsWith(t, "[\\") and endsWith(t, "\\]")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .parallelogram_alt };
        if (startsWith(t, "[/") and endsWith(t, "\\]")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .trapezoid };
        if (startsWith(t, "[\\") and endsWith(t, "/]")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .trapezoid_alt };
        if (startsWith(t, "[[") and endsWith(t, "]]")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .subroutine };
        if (startsWith(t, "[(") and endsWith(t, ")]")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .cylinder };
    }
    if (startsWith(t, "[") and endsWith(t, "]") and t.len >= 2) {
        const inner = t[1 .. t.len - 1];
        if (inner.len >= 2 and startsWith(inner, "(") and endsWith(inner, ")")) return .{ .label = try stripQuotes(a, inner[1 .. inner.len - 1]), .shape = .stadium };
        return .{ .label = try stripQuotes(a, inner), .shape = .rectangle };
    }
    return .{ .label = try stripQuotes(a, t), .shape = .rectangle };
}

fn parseShapeFromParens(a: Allocator, raw: []const u8) Allocator.Error!LabelShape {
    const t = trim(raw);
    if (t.len >= 6 and startsWith(t, "(((") and endsWith(t, ")))")) return .{ .label = try stripQuotes(a, inner2(t, 3)), .shape = .double_circle };
    if (t.len >= 4 and startsWith(t, "((") and endsWith(t, "))")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .double_circle };
    if (t.len >= 2 and startsWith(t, "(") and endsWith(t, ")")) {
        const inner = t[1 .. t.len - 1];
        if (inner.len >= 2 and startsWith(inner, "[") and endsWith(inner, "]")) return .{ .label = try stripQuotes(a, inner[1 .. inner.len - 1]), .shape = .stadium };
        return .{ .label = try stripQuotes(a, inner), .shape = .round_rect };
    }
    return .{ .label = try stripQuotes(a, t), .shape = .round_rect };
}

fn parseShapeFromBraces(a: Allocator, raw: []const u8) Allocator.Error!LabelShape {
    const t = trim(raw);
    if (t.len >= 4 and startsWith(t, "{{") and endsWith(t, "}}")) return .{ .label = try stripQuotes(a, inner2(t, 2)), .shape = .hexagon };
    if (t.len >= 2 and startsWith(t, "{") and endsWith(t, "}")) return .{ .label = try stripQuotes(a, t[1 .. t.len - 1]), .shape = .diamond };
    return .{ .label = try stripQuotes(a, t), .shape = .diamond };
}

pub fn stripQuotes(a: Allocator, input: []const u8) Allocator.Error![]const u8 {
    _ = a;
    const t = trim(input);
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    if (t.len >= 2 and t[0] == '\'' and t[t.len - 1] == '\'') return t[1 .. t.len - 1];
    return t;
}

fn addNodeToSubgraph(a: Allocator, graph: *Graph, idx: usize, node_id: []const u8) Allocator.Error!void {
    if (idx >= graph.subgraphs.items.len) return;
    const sub = &graph.subgraphs.items[idx];
    if (!sub.containsNode(node_id)) try sub.nodes.append(a, node_id);
}

fn addNodeToSubgraphs(a: Allocator, graph: *Graph, stack: []const usize, node_id: []const u8) Allocator.Error!void {
    if (stack.len == 0) return;
    for (graph.subgraphs.items, 0..) |*sub, idx| {
        if (std.mem.indexOfScalar(usize, stack, idx) != null) continue;
        if (sub.containsNode(node_id)) return;
    }
    for (stack) |idx| try addNodeToSubgraph(a, graph, idx, node_id);
}

// ---- class diagram helpers --------------------------------------------------------------

fn splitTrailingQuoted(input: []const u8) ?struct { before: []const u8, value: []const u8 } {
    const t = util.trimEnd(input);
    if (t.len == 0) return null;
    const q = t[t.len - 1];
    if (q != '"' and q != '\'') return null;
    var i = t.len - 1;
    while (i > 0) {
        i -= 1;
        if (t[i] == q) return .{ .before = t[0..i], .value = t[i + 1 .. t.len - 1] };
    }
    return null;
}

fn splitLeadingQuoted(input: []const u8) ?struct { value: []const u8, rest: []const u8 } {
    const t = util.trimStart(input);
    if (t.len == 0) return null;
    const q = t[0];
    if (q != '"' and q != '\'') return null;
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (t[i] == q) return .{ .value = t[1..i], .rest = t[i + 1 ..] };
    }
    return null;
}

fn splitMultiplicityLeft(input: []const u8) struct { []const u8, ?[]const u8 } {
    const t = trim(input);
    if (t.len == 0) return .{ "", null };
    if (splitTrailingQuoted(t)) |r| {
        const before = trim(r.before);
        if (before.len > 0 and r.value.len > 0) return .{ before, r.value };
    }
    return .{ t, null };
}

fn splitMultiplicityRight(input: []const u8) struct { []const u8, ?[]const u8 } {
    const t = trim(input);
    if (t.len == 0) return .{ "", null };
    if (splitLeadingQuoted(t)) |r| {
        const rest = trim(r.rest);
        if (rest.len > 0 and r.value.len > 0) return .{ rest, r.value };
    }
    return .{ t, null };
}

fn splitLabel(input: []const u8) struct { []const u8, ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, input, ':')) |i| {
        const label = trim(input[i + 1 ..]);
        const target = trim(input[0..i]);
        if (label.len > 0) return .{ target, label };
        return .{ target, null };
    }
    return .{ trim(input), null };
}

fn parseClassRelationLine(a: Allocator, line: []const u8) Allocator.Error!?struct { left: []const u8, right: []const u8, meta: EdgeMeta, label: ?[]const u8, start_label: ?[]const u8, end_label: ?[]const u8 } {
    _ = a;
    const tokens = [_][]const u8{ "<|..", "..|>", "<|--", "--|>", "*--", "--*", "o--", "--o", "<..", "..>", "<--", "-->", "..", "--" };
    for (tokens) |token| {
        const pos = std.mem.indexOf(u8, line, token) orelse continue;
        const left = trim(line[0..pos]);
        const right_part = trim(line[pos + token.len ..]);
        if (left.len == 0 or right_part.len == 0) continue;
        const rl = splitLabel(right_part);
        const ml = splitMultiplicityLeft(left);
        const mr = splitMultiplicityRight(rl[0]);
        return .{ .left = ml[0], .right = mr[0], .meta = edgeMetaFromClassToken(token), .label = rl[1], .start_label = ml[1], .end_label = mr[1] };
    }
    return null;
}

fn edgeMetaFromClassToken(token: []const u8) EdgeMeta {
    var m: EdgeMeta = .{};
    m.arrow_start = util.containsChar(token, '<');
    m.arrow_end = util.containsChar(token, '>');
    m.directed = m.arrow_start or m.arrow_end;
    m.style = if (util.contains(token, "..")) .dotted else .solid;
    if (startsWith(token, "*")) m.start_decoration = .diamond_filled;
    if (endsWith(token, "*")) m.end_decoration = .diamond_filled;
    if (startsWith(token, "o")) m.start_decoration = .diamond;
    if (endsWith(token, "o")) m.end_decoration = .diamond;
    if (util.containsChar(token, '|')) {
        if (m.arrow_start) m.arrow_start_kind = .open_triangle;
        if (m.arrow_end) m.arrow_end_kind = .open_triangle;
    } else {
        if (m.arrow_start) m.arrow_start_kind = .class_dependency;
        if (m.arrow_end) m.arrow_end_kind = .class_dependency;
    }
    return m;
}

fn parseClassDeclaration(a: Allocator, input: []const u8) Allocator.Error!?struct { id: []const u8, label: ?[]const u8, body: ?[]const u8, open_body: bool } {
    var rest = trim(input);
    if (rest.len == 0) return null;
    var body: ?[]const u8 = null;
    var open_body = false;
    if (std.mem.indexOfScalar(u8, rest, '{')) |open_idx| {
        const header = trim(rest[0..open_idx]);
        const tail = trim(rest[open_idx + 1 ..]);
        if (std.mem.indexOfScalar(u8, tail, '}')) |close_idx| {
            const b = trim(tail[0..close_idx]);
            if (b.len > 0) body = b;
        } else open_body = true;
        rest = header;
    }
    const lower = try util.lowerAscii(a, rest);
    if (util.find(lower, " as ")) |as_idx| {
        const label_part = trim(rest[0..as_idx]);
        const id_part = trim(rest[as_idx + 4 ..]);
        if (id_part.len > 0) return .{ .id = id_part, .label = try stripQuotes(a, label_part), .body = body, .open_body = open_body };
    }
    if (startsWith(rest, "\"") and endsWith(rest, "\"")) {
        const label = try stripQuotes(a, rest);
        return .{ .id = label, .label = label, .body = body, .open_body = open_body };
    }
    return .{ .id = try stripQuotes(a, rest), .label = null, .body = body, .open_body = open_body };
}

fn splitClassBody(a: Allocator, body: []const u8) Allocator.Error![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |part| {
        const t = trim(part);
        if (t.len == 0) continue;
        var li = util.lines(t);
        while (li.next()) |l| {
            const lt = trim(l);
            if (lt.len > 0) try entries.append(a, lt);
        }
    }
    return entries.items;
}

fn normalizeClassMethodSignature(a: Allocator, entry: []const u8) Allocator.Error![]const u8 {
    const t = trim(entry);
    const close_idx = std.mem.indexOfScalar(u8, t, ')') orelse return t;
    const sig = t[0 .. close_idx + 1];
    const rest = trim(t[close_idx + 1 ..]);
    if (rest.len == 0) return t;
    if (rest[0] == ':') return std.fmt.allocPrint(a, "{s} {s}", .{ sig, rest });
    if (util.contains(t, "):") or util.contains(t, ") :")) return t;
    return std.fmt.allocPrint(a, "{s} : {s}", .{ sig, rest });
}

fn parseClassMemberLine(line: []const u8) ?struct { id: []const u8, member: []const u8 } {
    const i = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const id = trim(line[0..i]);
    const member = trim(line[i + 1 ..]);
    if (id.len == 0 or member.len == 0) return null;
    if (util.containsChar(id, ' ')) return null;
    return .{ .id = id, .member = member };
}

fn normalizeClassId(a: Allocator, token: []const u8) Allocator.Error!struct { id: []const u8, label: ?[]const u8 } {
    const t = trim(token);
    if (startsWith(t, "\"") and endsWith(t, "\"")) {
        const label = try stripQuotes(a, t);
        return .{ .id = label, .label = label };
    }
    return .{ .id = t, .label = null };
}

fn isClassStereotype(entry: []const u8) bool {
    const t = trim(entry);
    return startsWith(t, "<<") and endsWith(t, ">>") and t.len > 4;
}

// ---- ER helpers --------------------------------------------------------------------------

fn isErCardChar(ch: u21) bool {
    return ch == '|' or ch == 'o' or ch == '{' or ch == '}';
}

fn splitErCardinalityLeft(a: Allocator, input: []const u8) Allocator.Error!struct { []const u8, ?[]const u8 } {
    const t = trim(input);
    if (t.len == 0) return .{ "", null };
    const cps = try util.chars(a, t);
    const len = cps.len;
    if (len >= 2 and isErCardChar(cps[len - 2]) and isErCardChar(cps[len - 1])) {
        return .{ trim(try util.encode(a, cps[0 .. len - 2])), try util.encode(a, cps[len - 2 ..]) };
    }
    if (isErCardChar(cps[len - 1])) return .{ trim(try util.encode(a, cps[0 .. len - 1])), try util.encode(a, cps[len - 1 ..]) };
    return .{ t, null };
}

fn splitErCardinalityRight(a: Allocator, input: []const u8) Allocator.Error!struct { []const u8, ?[]const u8 } {
    const t = trim(input);
    if (t.len == 0) return .{ "", null };
    const cps = try util.chars(a, t);
    const len = cps.len;
    if (len >= 2 and isErCardChar(cps[0]) and isErCardChar(cps[1])) {
        return .{ trim(try util.encode(a, cps[2..])), try util.encode(a, cps[0..2]) };
    }
    if (isErCardChar(cps[0])) return .{ trim(try util.encode(a, cps[1..])), try util.encode(a, cps[0..1]) };
    return .{ t, null };
}

fn normalizeErCardinality(token: []const u8) ?ir.EdgeDecoration {
    const t = trim(token);
    const eqs = struct {
        fn any(s: []const u8, opts: []const []const u8) bool {
            for (opts) |o| if (eql(s, o)) return true;
            return false;
        }
    }.any;
    if (eqs(t, &.{ "||", "|" })) return .crows_foot_one;
    if (eqs(t, &.{ "o|", "|o", "o" })) return .crows_foot_zero_one;
    if (eqs(t, &.{ "|{", "}|" })) return .crows_foot_many;
    if (eqs(t, &.{ "o{", "}o", "}", "{" })) return .crows_foot_zero_many;
    return null;
}

fn parseErRelationLine(a: Allocator, line: []const u8) Allocator.Error!?struct { left: []const u8, right: []const u8, label: ?[]const u8, left_decoration: ?ir.EdgeDecoration, right_decoration: ?ir.EdgeDecoration, style: ir.EdgeStyle } {
    var relation_part: []const u8 = trim(line);
    var label: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, line, ':')) |i| {
        const l = trim(line[i + 1 ..]);
        label = if (l.len == 0) null else l;
        relation_part = trim(line[0..i]);
    }
    var sep: usize = undefined;
    var style: ir.EdgeStyle = .solid;
    if (util.find(relation_part, "--")) |i| {
        sep = i;
    } else if (util.find(relation_part, "..")) |i| {
        sep = i;
        style = .dotted;
    } else return null;
    const left_part = trim(relation_part[0..sep]);
    const right_part = trim(relation_part[sep + 2 ..]);
    if (left_part.len == 0 or right_part.len == 0) return null;
    const l = try splitErCardinalityLeft(a, left_part);
    const r = try splitErCardinalityRight(a, right_part);
    if (l[0].len == 0 or r[0].len == 0) return null;
    const left_id = try stripQuotes(a, trim(l[0]));
    const right_id = try stripQuotes(a, trim(r[0]));
    if (left_id.len == 0 or right_id.len == 0) return null;
    return .{
        .left = left_id,
        .right = right_id,
        .label = label,
        .left_decoration = if (l[1]) |tok| normalizeErCardinality(tok) else null,
        .right_decoration = if (r[1]) |tok| normalizeErCardinality(tok) else null,
        .style = style,
    };
}

// ---- gantt helpers -----------------------------------------------------------------------

fn extractFrontmatterValue(input: []const u8, key: []const u8) ?[]const u8 {
    var in_fm = false;
    var it = util.lines(input);
    while (it.next()) |line| {
        const t = trim(line);
        if (eql(t, "---")) {
            if (in_fm) return null;
            in_fm = true;
            continue;
        }
        if (in_fm) if (std.mem.indexOfScalar(u8, t, ':')) |i| {
            if (eql(trim(t[0..i]), key)) {
                const v = trim(t[i + 1 ..]);
                if (v.len > 0) return v;
            }
        };
    }
    return null;
}

fn parseGanttTaskMeta(a: Allocator, meta: []const u8) Allocator.Error!struct { id: ?[]const u8, details: []const []const u8, after: ?[]const u8, status: ?ir.GanttStatus } {
    var id: ?[]const u8 = null;
    var details: std.ArrayList([]const u8) = .empty;
    var after: ?[]const u8 = null;
    var status: ?ir.GanttStatus = null;
    var it = std.mem.splitScalar(u8, meta, ',');
    while (it.next()) |raw| {
        const token = trim(raw);
        if (token.len == 0) continue;
        const lower = try util.lowerAscii(a, token);
        if (startsWith(lower, "after ")) {
            const dep = trim(lower["after ".len..]);
            if (dep.len > 0) after = dep;
            continue;
        }
        if (ganttStatusFromToken(lower)) |s| {
            status = s;
            try details.append(a, token);
            continue;
        }
        if (looksLikeDate(token) or looksLikeDuration(token)) {
            try details.append(a, token);
            continue;
        }
        if (id == null) id = token else try details.append(a, token);
    }
    return .{ .id = id, .details = details.items, .after = after, .status = status };
}

fn ganttStatusFromToken(t: []const u8) ?ir.GanttStatus {
    if (eql(t, "done")) return .done;
    if (eql(t, "active")) return .active;
    if (eql(t, "crit")) return .crit;
    if (eql(t, "milestone")) return .milestone;
    return null;
}

pub fn looksLikeDate(token: []const u8) bool {
    return util.containsChar(token, '-') or util.containsChar(token, '/') or util.containsChar(token, '.');
}

pub fn looksLikeDuration(token: []const u8) bool {
    if (token.len == 0) return false;
    const last = std.ascii.toLower(token[token.len - 1]);
    if (last != 'd' and last != 'h' and last != 'w' and last != 'm' and last != 'y') return false;
    if (token[token.len - 1] >= 0x80) return false;
    const digits = token[0 .. token.len - 1];
    if (digits.len == 0) return false;
    var any_digit = false;
    for (digits) |c| {
        if (c >= '0' and c <= '9') {
            any_digit = true;
        } else if (c != '.') return false;
    }
    return any_digit;
}

fn extractGanttTiming(details: []const []const u8) struct { start: ?[]const u8, duration: ?[]const u8 } {
    var start: ?[]const u8 = null;
    var duration: ?[]const u8 = null;
    for (details) |d| {
        if (looksLikeDate(d) and start == null) {
            start = d;
        } else if (looksLikeDuration(d) and duration == null) duration = d;
    }
    return .{ .start = start, .duration = duration };
}

// ---- state helpers -----------------------------------------------------------------------

fn trimStartMatchesState(s: []const u8) []const u8 {
    var r = s;
    while (startsWith(r, "state ")) r = r["state ".len..];
    return r;
}

fn parseStateAliasLine(a: Allocator, line: []const u8) Allocator.Error!?struct { id: []const u8, label: []const u8, classes: []const []const u8 } {
    const t = trim(line);
    if (!startsWith(t, "state ")) return null;
    if (util.containsChar(t, '{')) return null;
    const rest = trim(trimStartMatchesState(t));
    if (!startsWith(rest, "\"")) return null;
    const end_quote = (std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null) + 1;
    const label = rest[1..end_quote];
    const remaining = trim(rest[end_quote + 1 ..]);
    const lower = try util.lowerAscii(a, remaining);
    if (!startsWith(lower, "as ")) return null;
    const idc = try splitInlineClasses(a, trim(remaining[3..]));
    const id = try stripQuotes(a, trim(idc.base));
    if (id.len == 0) return null;
    return .{ .id = id, .label = label, .classes = idc.classes };
}

fn parseStateStereotype(a: Allocator, line: []const u8) Allocator.Error!struct { line: []const u8, shape: ?NodeShape, label_override: ?[]const u8 } {
    const t = trim(line);
    if (!startsWith(t, "state ")) return .{ .line = t, .shape = null, .label_override = null };
    const start = util.find(t, "<<") orelse return .{ .line = t, .shape = null, .label_override = null };
    const end = util.find(t[start + 2 ..], ">>") orelse return .{ .line = t, .shape = null, .label_override = null };
    const stereo = try util.lowerAscii(a, trim(t[start + 2 .. start + 2 + end]));
    const before = util.trimEnd(t[0..start]);
    const after = util.trimStart(t[start + 2 + end + 2 ..]);
    const cleaned = if (after.len == 0) before else if (before.len == 0) after else try std.fmt.allocPrint(a, "{s} {s}", .{ before, after });
    var shape: ?NodeShape = null;
    var label_override: ?[]const u8 = null;
    if (eql(stereo, "choice")) {
        shape = .diamond;
    } else if (eql(stereo, "fork") or eql(stereo, "join")) {
        shape = .fork_join;
        label_override = "";
    }
    return .{ .line = cleaned, .shape = shape, .label_override = label_override };
}

fn parseStateDescriptionLine(a: Allocator, line: []const u8) Allocator.Error!?struct { id: []const u8, desc: []const u8, classes: []const []const u8 } {
    const t = trim(line);
    if (t.len == 0) return null;
    const lower = try util.lowerAscii(a, t);
    if (startsWith(lower, "note ")) return null;
    const rest = if (startsWith(t, "state ")) trim(t[6..]) else t;
    if (util.contains(try util.lowerAscii(a, rest), " as ")) return null;
    var sep: ?usize = null;
    var idx: usize = 0;
    while (idx < rest.len) {
        if (rest[idx] == ':') {
            if (idx + 2 < rest.len and rest[idx + 1] == ':' and rest[idx + 2] == ':') {
                idx += 3;
                continue;
            }
            sep = idx;
            break;
        }
        idx += 1;
    }
    const s = sep orelse return null;
    const idc = try splitInlineClasses(a, trim(rest[0..s]));
    const id = try stripQuotes(a, trim(idc.base));
    const desc = try stripQuotes(a, trim(rest[s + 1 ..]));
    if (id.len == 0 or desc.len == 0) return null;
    return .{ .id = id, .desc = desc, .classes = idc.classes };
}

fn stateDisplayLabel(a: Allocator, id: []const u8, labels: *const ir.StrMap([]const u8), descriptions: *const ir.StrMap(std.ArrayList([]const u8))) Allocator.Error![]const u8 {
    const title = labels.get(id) orelse id;
    const ds = descriptions.get(id) orelse return title;
    if (ds.items.len == 0) return title;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, title);
    try out.appendSlice(a, "\n---");
    for (ds.items) |d| {
        try out.append(a, '\n');
        try out.appendSlice(a, d);
    }
    return out.items;
}

fn stateDisplayLabelOption(a: Allocator, id: []const u8, labels: *const ir.StrMap([]const u8), descriptions: *const ir.StrMap(std.ArrayList([]const u8))) Allocator.Error!?[]const u8 {
    if (labels.contains(id) or descriptions.contains(id)) return try stateDisplayLabel(a, id, labels, descriptions);
    return null;
}

fn parseStateNote(a: Allocator, line: []const u8) Allocator.Error!?struct { position: ir.StateNotePosition, target: []const u8, label: []const u8 } {
    const t = trim(line);
    const lower = try util.lowerAscii(a, t);
    if (!startsWith(lower, "note ")) return null;
    const rest = trim(t[4..]);
    const lr = try util.lowerAscii(a, rest);
    var position: ir.StateNotePosition = undefined;
    var targets: []const u8 = undefined;
    if (startsWith(lr, "right of ")) {
        position = .right_of;
        targets = trim(rest[9..]);
    } else if (startsWith(lr, "left of ")) {
        position = .left_of;
        targets = trim(rest[8..]);
    } else return null;
    const c = std.mem.indexOfScalar(u8, targets, ':') orelse return null;
    const target = trim(targets[0..c]);
    const label = trim(targets[c + 1 ..]);
    if (target.len == 0 or label.len == 0) return null;
    return .{ .position = position, .target = target, .label = label };
}

fn parseStateTransition(a: Allocator, line: []const u8) Allocator.Error!?struct { left: []const u8, meta: EdgeMeta, right: []const u8, label: ?[]const u8 } {
    _ = a;
    const tokens = [_][]const u8{ "<-->", "<--", "-->", "<->", "->", "<-", "..>", "<.." };
    for (tokens) |token| {
        const pos = std.mem.indexOf(u8, line, token) orelse continue;
        const left = trim(line[0..pos]);
        const right_part = trim(line[pos + token.len ..]);
        if (left.len == 0 or right_part.len == 0) continue;
        const rl = splitLabel(right_part);
        var m: EdgeMeta = .{};
        m.arrow_start = util.containsChar(token, '<');
        m.arrow_end = util.containsChar(token, '>');
        m.directed = m.arrow_start or m.arrow_end;
        m.style = if (util.contains(token, "..")) .dotted else .solid;
        return .{ .left = left, .meta = m, .right = rl[0], .label = rl[1] };
    }
    return null;
}

fn normalizeStateToken(
    a: Allocator,
    token: []const u8,
    is_start: bool,
    start_states: *ir.StrMap([]const u8),
    end_states: *ir.StrMap([]const u8),
    start_order: *std.ArrayList([]const u8),
    end_order: *std.ArrayList([]const u8),
    scope: []const u8,
) Allocator.Error!struct { id: []const u8, shape: NodeShape, label_override: ?[]const u8 } {
    const t = trim(token);
    if (eql(t, "[*]") or eql(t, "*")) {
        if (is_start) {
            const gop = try start_states.getOrPut(a, scope);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.fmt.allocPrint(a, "__start_{s}__", .{scope});
                try start_order.append(a, scope);
            }
            return .{ .id = gop.value_ptr.*, .shape = .circle, .label_override = "" };
        }
        const gop = try end_states.getOrPut(a, scope);
        if (!gop.found_existing) {
            gop.value_ptr.* = try std.fmt.allocPrint(a, "__end_{s}__", .{scope});
            try end_order.append(a, scope);
        }
        return .{ .id = gop.value_ptr.*, .shape = .double_circle, .label_override = "" };
    }
    return .{ .id = try stripQuotes(a, t), .shape = .round_rect, .label_override = null };
}

fn parseStateSimple(a: Allocator, line: []const u8) Allocator.Error!?struct { id: []const u8, classes: []const []const u8 } {
    const t = trim(line);
    if (!startsWith(t, "state ")) return null;
    if (util.containsChar(t, '{')) return null;
    var rest = trim(trimStartMatchesState(t));
    if (util.contains(try util.lowerAscii(a, rest), " as ")) return null;
    if (std.mem.indexOfScalar(u8, rest, '{')) |i| rest = trim(rest[0..i]);
    if (rest.len == 0) return null;
    const idc = try splitInlineClasses(a, rest);
    const id = try stripQuotes(a, trim(idc.base));
    if (id.len == 0) return null;
    return .{ .id = id, .classes = idc.classes };
}

fn parseStateContainerHeader(a: Allocator, line: []const u8) Allocator.Error!?struct { id: ?[]const u8, label: []const u8, tail: []const u8 } {
    const t = trim(line);
    if (!startsWith(t, "state ")) return null;
    const brace = std.mem.indexOfScalar(u8, t, '{') orelse return null;
    const head = trim(t[0..brace]);
    const tail = trim(t[brace + 1 ..]);
    const rest = trim(trimStartMatchesState(head));
    if (rest.len == 0) return null;
    if (startsWith(rest, "\"")) {
        const end_quote = (std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null) + 1;
        const label = rest[1..end_quote];
        const remaining = trim(rest[end_quote + 1 ..]);
        if (startsWith(try util.lowerAscii(a, remaining), "as ")) {
            const id = trim(remaining[3..]);
            if (id.len == 0) return null;
            return .{ .id = id, .label = label, .tail = tail };
        }
        return .{ .id = null, .label = label, .tail = tail };
    }
    const lower = try util.lowerAscii(a, rest);
    if (util.find(lower, " as ")) |as_idx| {
        const id_part = trim(rest[0..as_idx]);
        const label_part = trim(rest[as_idx + 4 ..]);
        if (id_part.len == 0 or label_part.len == 0) return null;
        return .{ .id = try stripQuotes(a, id_part), .label = try stripQuotes(a, label_part), .tail = tail };
    }
    const id = try stripQuotes(a, rest);
    return .{ .id = id, .label = id, .tail = tail };
}

// ---- sequence helpers ----------------------------------------------------------------------

fn parseSequenceParticipant(a: Allocator, line: []const u8) Allocator.Error!?struct { id: []const u8, label: ?[]const u8, shape: NodeShape } {
    const lowered = try util.lowerAscii(a, line);
    const keywords = [_]struct { []const u8, NodeShape }{
        .{ "participant ", .actor_box }, .{ "actor ", .actor_box },  .{ "boundary ", .actor_box },
        .{ "control ", .actor_box },     .{ "entity ", .actor_box }, .{ "database ", .cylinder },
    };
    var rest: ?[]const u8 = null;
    var shape: NodeShape = .actor_box;
    for (keywords) |k| if (startsWith(lowered, k[0])) {
        rest = trim(line[k[0].len..]);
        shape = k[1];
        break;
    };
    const r = rest orelse return null;
    if (r.len == 0) return null;
    const lr = try util.lowerAscii(a, r);
    if (util.find(lr, " as ")) |as_idx| {
        const label_part = trim(r[0..as_idx]);
        const id_part = trim(r[as_idx + 4 ..]);
        if (id_part.len == 0) return null;
        return .{ .id = try stripQuotes(a, label_part), .label = try stripQuotes(a, id_part), .shape = shape };
    }
    if (startsWith(r, "\"") and endsWith(r, "\"")) {
        const label = try stripQuotes(a, r);
        return .{ .id = label, .label = label, .shape = shape };
    }
    return .{ .id = try stripQuotes(a, r), .label = null, .shape = shape };
}

fn isColorToken(a: Allocator, token: []const u8) Allocator.Error!bool {
    const lower = try util.lowerAscii(a, trim(token));
    return eql(lower, "transparent") or startsWith(lower, "#") or startsWith(lower, "rgb(") or startsWith(lower, "rgba(") or startsWith(lower, "hsl(") or startsWith(lower, "hsla(");
}

fn parseSequenceBoxLine(a: Allocator, line: []const u8) Allocator.Error!?struct { color: ?[]const u8, label: ?[]const u8 } {
    const t = trim(line);
    const lower = try util.lowerAscii(a, t);
    if (!startsWith(lower, "box")) return null;
    const rest = trim(t[3..]);
    if (rest.len == 0) return .{ .color = null, .label = null };
    const tokens = try tokenizeQuoted(a, rest);
    if (tokens.len == 0) return .{ .color = null, .label = null };
    const first = tokens[0];
    if (std.ascii.eqlIgnoreCase(first, "transparent")) {
        const label = try util.join(a, tokens[1..], " ");
        return .{ .color = null, .label = if (trim(label).len == 0) null else label };
    }
    var color: ?[]const u8 = if (tokens.len > 1) first else if (try isColorToken(a, first)) first else null;
    var label: ?[]const u8 = if (tokens.len > 1) try util.join(a, tokens[1..], " ") else if (color == null) first else null;
    if (label) |l| if (trim(l).len == 0) {
        label = null;
    };
    if (color) |c| if (std.ascii.eqlIgnoreCase(c, "transparent")) {
        color = null;
    };
    return .{ .color = color, .label = label };
}

fn ensureSequenceNode(a: Allocator, graph: *Graph, labels: *const ir.StrMap([]const u8), id: []const u8, shape: ?NodeShape) Allocator.Error!void {
    const label = labels.get(id);
    if (shape) |s| return graph.ensureNode(a, id, label, s);
    if (graph.nodes.contains(id)) return graph.ensureNode(a, id, label, null);
    return graph.ensureNode(a, id, label, .actor_box);
}

fn parseSequenceMessage(a: Allocator, line: []const u8) Allocator.Error!?struct { from: []const u8, to: []const u8, label: ?[]const u8, style: ir.EdgeStyle, activation: ?ir.SequenceActivationKind } {
    _ = a;
    const tokens = [_][]const u8{ "-->>+", "->>+", "-->+", "->+", "-->>-", "->>-", "-->-", "->-", "<--+", "<-+", "<--", "<-", "-->>", "->>", "-->", "->" };
    for (tokens) |token| {
        const pos = std.mem.indexOf(u8, line, token) orelse continue;
        const left = trim(line[0..pos]);
        const right_part = trim(line[pos + token.len ..]);
        if (left.len == 0 or right_part.len == 0) continue;
        const rl = splitLabel(right_part);
        var from = left;
        var to = rl[0];
        if (token[0] == '<') std.mem.swap([]const u8, &from, &to);
        var tr = std.mem.trimStart(u8, token, "<");
        tr = std.mem.trimEnd(u8, tr, "+-");
        const style: ir.EdgeStyle = if (startsWith(tr, "--")) .dotted else .solid;
        const activation: ?ir.SequenceActivationKind = if (endsWith(token, "+")) .activate else if (endsWith(token, "-")) .deactivate else null;
        return .{ .from = from, .to = to, .label = rl[1], .style = style, .activation = activation };
    }
    return null;
}

fn parseSequenceNote(a: Allocator, line: []const u8) Allocator.Error!?struct { position: ir.SequenceNotePosition, participants: []const []const u8, label: []const u8 } {
    const t = trim(line);
    const lower = try util.lowerAscii(a, t);
    if (!startsWith(lower, "note ")) return null;
    const rest = trim(t[4..]);
    const lr = try util.lowerAscii(a, rest);
    var position: ir.SequenceNotePosition = undefined;
    var targets: []const u8 = undefined;
    if (startsWith(lr, "left of ")) {
        position = .left_of;
        targets = trim(rest[8..]);
    } else if (startsWith(lr, "right of ")) {
        position = .right_of;
        targets = trim(rest[9..]);
    } else if (startsWith(lr, "over ")) {
        position = .over;
        targets = trim(rest[5..]);
    } else return null;
    const c = std.mem.indexOfScalar(u8, targets, ':') orelse return null;
    const label = trim(targets[c + 1 ..]);
    if (label.len == 0) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, targets[0..c], ',');
    while (it.next()) |p| {
        const s = try stripQuotes(a, trim(p));
        if (s.len > 0) try parts.append(a, s);
    }
    if (parts.items.len == 0) return null;
    return .{ .position = position, .participants = parts.items, .label = label };
}

test "flowchart parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = try Parser.init(arena.allocator());
    const g = try p.parse("flowchart LR\n  A[Start] -->|Yes| B{Decide}\n  B --> C & D");
    try std.testing.expectEqual(ir.Direction.left_right, g.direction);
    try std.testing.expectEqual(@as(usize, 4), g.nodes.len());
    try std.testing.expectEqual(@as(usize, 3), g.edges.items.len);
    try std.testing.expectEqualStrings("Yes", g.edges.items[0].label.?);
    try std.testing.expectEqual(NodeShape.diamond, g.nodes.get("B").?.shape);
}
