//! Made-up work history: the tour's sample database and the screenshots in
//! the docs. Every task, client and note here is invented. The same seed
//! gives the same days in every language, so a scene lines up across them.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const zone_mod = @import("zone.zig");

pub const Lang = enum { en, pt, ja };

pub fn langOf(text: []const u8) ?Lang {
    return std.meta.stringToEnum(Lang, text);
}

/// Provider field names the sample tasks carry.
pub const field_names = [_][]const u8{ "Client", "System", "Situation" };

const Task = struct { ref: []const u8, client: []const u8, system: u8, situation: u8 };

// Systems: billing, warehouse, portal, reports, purchasing, sales, hr, platform.
// Situations: in progress, testing, waiting, done, analysis.
const tasks = [_]Task{
    .{ .ref = "48213", .client = "Northwind", .system = 0, .situation = 0 },
    .{ .ref = "48177", .client = "Contoso", .system = 1, .situation = 1 },
    .{ .ref = "48302", .client = "Fabrikam", .system = 0, .situation = 0 },
    .{ .ref = "47958", .client = "Tailspin", .system = 2, .situation = 2 },
    .{ .ref = "48251", .client = "Northwind", .system = 3, .situation = 0 },
    .{ .ref = "48120", .client = "Contoso", .system = 1, .situation = 3 },
    .{ .ref = "48333", .client = "Fabrikam", .system = 4, .situation = 4 },
    .{ .ref = "48089", .client = "Tailspin", .system = 5, .situation = 1 },
    .{ .ref = "48266", .client = "Litware", .system = 6, .situation = 0 },
    .{ .ref = "48347", .client = "Litware", .system = 7, .situation = 4 },
};

pub const Text = struct {
    titles: [tasks.len][]const u8,
    systems: [8][]const u8,
    situations: [5][]const u8,
    internal: [4][]const u8,
    notes: [12][]const u8,
    summaries: [6][]const u8,
    /// The title a looked-up ref gets when it is not one of the sample tasks.
    ticket: []const u8,
};

pub const texts = std.EnumArray(Lang, Text).init(.{
    .en = .{
        .titles = .{
            "Invoice export drops rows with accented customer names",
            "Warehouse picking list ignores the bin order",
            "New tax rule for interstate shipments",
            "Customer portal login loops after password reset",
            "Monthly sales report times out for large regions",
            "Barcode scanner adds a trailing space to lot numbers",
            "Supplier import maps the wrong currency field",
            "Credit limit check skips orders entered offline",
            "Payroll export rounds overtime twice",
            "Upgrade the PDF generator used by delivery notes",
        },
        .systems = .{ "Billing", "Warehouse", "Portal", "Reports", "Purchasing", "Sales", "HR", "Platform" },
        .situations = .{ "In progress", "Testing", "Waiting", "Done", "Analysis" },
        .internal = .{ "Team stand-up", "Code review", "Sprint planning", "Environment setup" },
        .notes = .{
            "Reproduced with the sample file from the ticket",
            "Root cause: the export reads the name before decoding it",
            "Fix ready, waiting for the test environment",
            "Asked the client for a second example",
            "Wrote the migration script, dry run looks right",
            "Pair session on the query plan",
            "Added a regression test for the edge case",
            "Deployed to staging, smoke test passed",
            "Customer confirmed the fix on their side",
            "Split the change in two, first part merged",
            "Index on order date cuts the report to 4s",
            "Waiting on the supplier for the new layout",
        },
        .summaries = .{
            "Closed the invoice export fix and started on the tax rule.",
            "Mostly analysis: supplier import and the report timeout.",
            "Testing day: picking list and credit limit both verified.",
            "Portal login fix waiting on the client; review backlog cleared.",
            "Report timeout solved with an index; PDF upgrade scoped.",
            "Payroll rounding traced to the export; patch under review.",
        },
        .ticket = "Sample ticket",
    },
    .pt = .{
        .titles = .{
            "Exportação de faturas perde linhas com nomes acentuados",
            "Lista de separação do armazém ignora a ordem das posições",
            "Nova regra de imposto para envios interestaduais",
            "Login do portal do cliente entra em loop após redefinir a senha",
            "Relatório mensal de vendas expira em regiões grandes",
            "Leitor de código de barras adiciona espaço no fim do lote",
            "Importação de fornecedores usa o campo de moeda errado",
            "Verificação de limite de crédito ignora pedidos offline",
            "Exportação da folha arredonda horas extras duas vezes",
            "Atualizar o gerador de PDF das notas de entrega",
        },
        .systems = .{ "Faturamento", "Armazém", "Portal", "Relatórios", "Compras", "Vendas", "RH", "Plataforma" },
        .situations = .{ "Em andamento", "Em teste", "Aguardando", "Concluída", "Em análise" },
        .internal = .{ "Reunião diária", "Revisão de código", "Planejamento da sprint", "Configuração do ambiente" },
        .notes = .{
            "Reproduzido com o arquivo de exemplo do chamado",
            "Causa: a exportação lê o nome antes de decodificar",
            "Correção pronta, aguardando o ambiente de testes",
            "Pedi ao cliente um segundo exemplo",
            "Script de migração escrito, simulação parece correta",
            "Sessão em dupla sobre o plano da consulta",
            "Adicionado teste de regressão para o caso limite",
            "Publicado em homologação, teste rápido passou",
            "Cliente confirmou a correção do lado dele",
            "Mudança dividida em duas, primeira parte integrada",
            "Índice na data do pedido reduz o relatório a 4s",
            "Aguardando o fornecedor enviar o novo layout",
        },
        .summaries = .{
            "Fechei a correção da exportação de faturas e comecei a regra de imposto.",
            "Dia de análise: importação de fornecedores e lentidão do relatório.",
            "Dia de testes: lista de separação e limite de crédito verificados.",
            "Login do portal aguardando o cliente; revisões em dia.",
            "Lentidão do relatório resolvida com um índice; atualização do PDF planejada.",
            "Arredondamento da folha rastreado até a exportação; correção em revisão.",
        },
        .ticket = "Chamado de exemplo",
    },
    .ja = .{
        .titles = .{
            "請求書エクスポートでアクセント付きの顧客名の行が欠落する",
            "倉庫のピッキングリストが棚番の順序を無視する",
            "州間配送の新しい税ルール",
            "パスワード再設定後に顧客ポータルのログインがループする",
            "月次売上レポートが大きな地域でタイムアウトする",
            "バーコードスキャナーがロット番号の末尾に空白を付ける",
            "仕入先インポートが誤った通貨フィールドを使う",
            "与信限度チェックがオフライン入力の注文を素通りする",
            "給与エクスポートで残業時間が二重に丸められる",
            "納品書の PDF 生成ツールを更新する",
        },
        .systems = .{ "請求", "倉庫", "ポータル", "レポート", "購買", "販売", "人事", "基盤" },
        .situations = .{ "対応中", "テスト中", "回答待ち", "完了", "調査中" },
        .internal = .{ "朝会", "コードレビュー", "スプリント計画", "環境構築" },
        .notes = .{
            "チケットのサンプルファイルで再現した",
            "原因: エクスポートがデコード前に名前を読んでいる",
            "修正済み、テスト環境の空き待ち",
            "顧客に別の例を依頼した",
            "移行スクリプトを作成、ドライランは問題なし",
            "クエリプランについてペア作業",
            "境界ケースの回帰テストを追加",
            "ステージングに反映、スモークテスト通過",
            "顧客側で修正を確認してもらった",
            "変更を二つに分割、前半はマージ済み",
            "注文日のインデックスでレポートが 4 秒に短縮",
            "新しいレイアウトを仕入先から受領待ち",
        },
        .summaries = .{
            "請求書エクスポートの修正を完了し、税ルールに着手。",
            "主に調査: 仕入先インポートとレポートのタイムアウト。",
            "テストの日: ピッキングリストと与信限度を確認。",
            "ポータルのログインは顧客待ち。レビューは消化済み。",
            "レポートのタイムアウトをインデックスで解決。PDF 更新を見積もり。",
            "給与の丸めはエクスポートが原因と特定。修正はレビュー中。",
        },
        .ticket = "サンプルチケット",
    },
});

pub const Options = struct {
    lang: Lang,
    /// Binding namespace of the provider the sample refs belong to.
    instance: []const u8,
    now_ms: i64,
    zone: *const zone_mod.Zone,
    /// Also work earlier today, ending a few minutes before `now_ms`, paused.
    today: bool = true,
    seed: u64 = 7,
};

const Span = struct { task: i64, a: i64, b: i64 };

const Seeder = struct {
    db: *sqlite.Db,
    o: Options,
    rnd: std.Random,
    text: *const Text,

    fn exec(s: *Seeder, sql: []const u8, args: anytype) !void {
        var st = try s.db.prepare(sql);
        defer st.finalize();
        inline for (args, 1..) |arg, i| {
            switch (@TypeOf(arg)) {
                i64, comptime_int => try st.bindI64(i, arg),
                ?[]const u8 => try st.bindOptionalText(i, arg),
                else => try st.bindText(i, arg),
            }
        }
        _ = try st.step();
    }

    fn task(s: *Seeder, title: []const u8, created: i64) !i64 {
        try s.exec("INSERT INTO tasks(title, created_ms) VALUES(?,?)", .{ title, created });
        return s.db.lastInsertRowid();
    }

    fn range(s: *Seeder, lo: i64, hi: i64) i64 {
        return s.rnd.intRangeAtMost(i64, lo, hi);
    }

    fn chance(s: *Seeder, p: f64) bool {
        return s.rnd.float(f64) < p;
    }

    /// Focus spans from `start` up to `stop`, rotating through `main`, with
    /// the occasional code review.
    fn fill(s: *Seeder, spans: *std.ArrayList(Span), a: std.mem.Allocator, main: []const i64, review: i64, start: i64, stop: i64) !i64 {
        var t = start;
        while (t < stop - 10) {
            var pick = if (s.chance(0.15)) review else main[@intCast(s.range(0, @intCast(main.len - 1)))];
            if (spans.items.len > 0 and spans.items[spans.items.len - 1].task == pick) {
                pick = for (main, 0..) |m, i| {
                    if (m == pick) break main[(i + 1) % main.len];
                } else main[0];
            }
            const length = @min(stop - t, s.range(25, 110));
            try spans.append(a, .{ .task = pick, .a = t, .b = t + length });
            const gaps = [_]i64{ 0, 0, 0, 1, 2, 5 };
            t += length + gaps[@intCast(s.range(0, gaps.len - 1))];
        }
        return t;
    }

    fn intervals(s: *Seeder, day_start: i64, spans: []const Span, lunch_out: ?i64, last_closed: []const u8, bound: []const i64) !void {
        for (spans, 0..) |sp, i| {
            const after_lunch = if (lunch_out) |l| i > 0 and spans[i - 1].b <= l and l < sp.a else false;
            const before_lunch = if (lunch_out) |l| i + 1 < spans.len and sp.b <= l and l < spans[i + 1].a else false;
            const opened: []const u8 = if (after_lunch) "resume" else "switch";
            const closed: []const u8 = if (i == spans.len - 1) last_closed else if (before_lunch) "pause" else "switch";
            try s.exec("INSERT INTO intervals(task_id, role, start_ms, end_ms, opened_by, closed_by) VALUES(?,'focus',?,?,?,?)", .{ sp.task, day_start + sp.a * 60_000, day_start + sp.b * 60_000, opened, closed });
            const id = s.db.lastInsertRowid();
            const is_bound = std.mem.indexOfScalar(i64, bound, sp.task) != null;
            if (is_bound and sp.b - sp.a >= 40 and s.chance(0.45)) {
                const at = sp.a + s.range(10, sp.b - sp.a - 5);
                try s.exec("INSERT INTO notes(interval_id, at_ms, text) VALUES(?,?,?)", .{ id, day_start + at * 60_000, s.text.notes[@intCast(s.range(0, s.text.notes.len - 1))] });
            }
        }
    }
};

/// 0 = Sunday.
fn weekday(d: zone_mod.Zone.Date) u8 {
    const y: i64 = if (d.month <= 2) @as(i64, d.year) - 1 else d.year;
    const m: i64 = if (d.month <= 2) @as(i64, d.month) + 12 else d.month;
    const k = @mod(y, 100);
    const j = @divFloor(y, 100);
    const h = @mod(@as(i64, d.day) + @divFloor(13 * (m + 1), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) + 5 * j, 7);
    // Zeller: 0 = Saturday.
    return @intCast(@mod(h + 6, 7));
}

fn dateText(buffer: []u8, d: zone_mod.Zone.Date) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, d.year), @as(u32, d.month), @as(u32, d.day) }) catch unreachable;
}

/// Fills an empty database: refuses one that already has tasks, so made-up
/// history never mixes with real history.
pub fn seed(db: *sqlite.Db, gpa: std.mem.Allocator, o: Options) !void {
    {
        var st = try db.prepare("SELECT count(*) FROM tasks");
        defer st.finalize();
        _ = try st.step();
        if (st.columnI64(0) != 0) return error.NotEmpty;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(o.seed);
    var s: Seeder = .{ .db = db, .o = o, .rnd = prng.random(), .text = texts.getPtrConst(o.lang) };

    var tx = try db.transaction();
    defer tx.deinit();

    const today = try o.zone.dateOf(o.now_ms);
    const today_bounds = try o.zone.dayBounds(today.year, today.month, today.day);
    const created = today_bounds.start_ms - 40 * 86_400_000;

    var bound: [tasks.len]i64 = undefined;
    for (tasks, 0..) |t, i| {
        bound[i] = try s.task(s.text.titles[i], created);
        try s.exec("INSERT INTO task_bindings VALUES(?,?,?)", .{ bound[i], o.instance, t.ref });
        const values = [_][]const u8{ t.client, s.text.systems[t.system], s.text.situations[t.situation] };
        for (field_names, values) |name, value| try s.exec("INSERT INTO task_fields VALUES(?,?,?)", .{ bound[i], name, value });
    }
    var internal: [4]i64 = undefined;
    for (s.text.internal, 0..) |title, i| internal[i] = try s.task(title, created);
    const standup = internal[0];
    const review = internal[1];

    // The weekdays of the four weeks before today, oldest first.
    var days: std.ArrayList(zone_mod.Zone.Date) = .empty;
    var back: i64 = 28;
    while (back >= 1) : (back -= 1) {
        const d = try o.zone.dateOf(today_bounds.start_ms - back * 86_400_000 + 12 * 3_600_000);
        const w = weekday(d);
        if (w != 0 and w != 6) try days.append(a, d);
    }

    for (days.items, 0..) |day, n| {
        const bounds = try o.zone.dayBounds(day.year, day.month, day.day);
        const shift = (n / 3) % tasks.len;
        var window: [tasks.len]i64 = undefined;
        for (0..tasks.len) |i| window[i] = bound[(i + shift) % tasks.len];
        const main = window[0..3];
        const start = 8 * 60 + s.range(20, 55);
        const lunch_out = 12 * 60 + s.range(0, 40);
        const lunch_back = lunch_out + s.range(60, 75);
        const end = start + 510 + s.range(-25, 40) + (lunch_back - lunch_out);

        var spans: std.ArrayList(Span) = .empty;
        try spans.append(a, .{ .task = standup, .a = start, .b = start + 15 });
        _ = try s.fill(&spans, a, main, review, start + 15 + s.range(0, 3), lunch_out);
        _ = try s.fill(&spans, a, main, review, lunch_back, end);
        // The latest workday has one interval split in two, so there is
        // something to merge.
        if (n == days.items.len - 1) {
            var longest: usize = 0;
            for (spans.items, 0..) |sp, i| {
                if (sp.b - sp.a > spans.items[longest].b - spans.items[longest].a) longest = i;
            }
            const sp = spans.items[longest];
            const mid = sp.a + @divFloor(sp.b - sp.a, 2);
            spans.items[longest].b = mid;
            try spans.insert(a, longest + 1, .{ .task = sp.task, .a = mid, .b = sp.b });
        }
        try s.intervals(bounds.start_ms, spans.items, lunch_out, "stop", &bound);

        // Now and then a task runs in parallel, watched but not counted.
        if (s.chance(0.3)) {
            const pa = lunch_back + s.range(20, 60);
            try s.exec("INSERT INTO intervals(task_id, role, start_ms, end_ms, opened_by, closed_by) VALUES(?,'parallel',?,?,'parallel','switch')", .{ window[4], bounds.start_ms + pa * 60_000, bounds.start_ms + (pa + s.range(20, 45)) * 60_000 });
        }
        var date_buffer: [10]u8 = undefined;
        const date = dateText(&date_buffer, day);
        if (n < days.items.len - 1 and s.chance(0.7)) {
            try s.exec("INSERT INTO day_summaries(day, text) VALUES(?,?)", .{ date, s.text.summaries[@intCast(s.range(0, s.text.summaries.len - 1))] });
        }

        // Older days are posted in full, last week partly, the last two days not at all.
        const age = days.items.len - 1 - n;
        if (age < 2) continue;
        var minutes: [tasks.len]i64 = @splat(0);
        for (spans.items) |sp| {
            if (std.mem.indexOfScalar(i64, &bound, sp.task)) |i| minutes[i] += sp.b - sp.a;
        }
        var first = true;
        for (minutes, 0..) |m, i| {
            if (m == 0) continue;
            defer first = false;
            if (age < 5 and first) continue;
            const hundredths = @divFloor(m * 100 + 59, 60);
            var amount_buffer: [16]u8 = undefined;
            const amount = std.fmt.bufPrint(&amount_buffer, "{d}.{d:0>2}", .{ @as(u64, @intCast(@divFloor(hundredths, 100))), @as(u64, @intCast(@mod(hundredths, 100))) }) catch unreachable;
            const when = bounds.start_ms + (end + 5) * 60_000;
            try s.exec("INSERT INTO postings(day, task_id, provider_instance, external_ref, state, amount_text, amount_micro, provider_data, created_ms, confirmed_ms) VALUES(?,?,?,?,'confirmed',?,?,'{\"demo\":true}',?,?)", .{ date, bound[i], o.instance, tasks[i].ref, amount, hundredths * 10_000, when, when });
        }
    }

    // Today: work from the morning up to a few minutes ago, then paused.
    if (o.today) {
        const local = try o.zone.localOf(o.now_ms);
        const now_min: i64 = @as(i64, local.hour) * 60 + local.minute;
        const stop = now_min - 5;
        const start = @min(8 * 60 + 40, stop - 90);
        if (start >= 0) {
            var spans: std.ArrayList(Span) = .empty;
            const main = [_]i64{ bound[0], bound[2], bound[7] };
            try spans.append(a, .{ .task = standup, .a = start, .b = start + 15 });
            var lunch: ?i64 = null;
            if (stop > 13 * 60 + 30 and start < 12 * 60) {
                _ = try s.fill(&spans, a, &main, review, start + 15, 12 * 60);
                lunch = 12 * 60;
                _ = try s.fill(&spans, a, &main, review, 13 * 60 + 5, stop);
            } else {
                _ = try s.fill(&spans, a, &main, review, start + 15, stop);
            }
            // The last span ends exactly at `stop`.
            const last = &spans.items[spans.items.len - 1];
            last.b = @max(last.a + 5, stop);
            try s.intervals(today_bounds.start_ms, spans.items, lunch, "pause", &bound);
            // A pause remembers what it closed, so play resumes it.
            try s.exec("INSERT INTO saved_set(task_id, role) VALUES(?,'focus')", .{last.task});
        }
    }

    try s.exec("INSERT OR REPLACE INTO settings(key, value) VALUES('ui_lang', ?)", .{@tagName(o.lang)});
    try tx.commit();
}

test "weekday follows the calendar" {
    try std.testing.expectEqual(@as(u8, 0), weekday(.{ .year = 2026, .month = 10, .day = 11 }));
    try std.testing.expectEqual(@as(u8, 5), weekday(.{ .year = 2026, .month = 10, .day = 9 }));
    try std.testing.expectEqual(@as(u8, 4), weekday(.{ .year = 2024, .month = 2, .day = 29 }));
    try std.testing.expectEqual(@as(u8, 3), weekday(.{ .year = 2000, .month = 1, .day = 5 }));
}

fn testCount(db: *sqlite.Db, sql: []const u8) !i64 {
    var st = try db.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnI64(0);
}

test "seed writes the same days in every language, today paused, and only into an empty database" {
    const store_mod = @import("store.zig");
    const zone_id = try zone_mod.currentId(std.testing.allocator);
    defer std.testing.allocator.free(zone_id);
    const zone = try zone_mod.Zone.load(zone_id);
    // A Friday afternoon.
    const now = (try zone.dayBounds(2026, 10, 9)).start_ms + 15 * 3_600_000;
    var shapes: [2][4]i64 = undefined;
    for ([_]Lang{ .en, .ja }, 0..) |lang, i| {
        var db: sqlite.Db = .{};
        try db.open(":memory:");
        defer db.close();
        _ = try store_mod.Store.init(&db, std.testing.allocator);
        try seed(&db, std.testing.allocator, .{ .lang = lang, .instance = "example", .now_ms = now, .zone = &zone });
        shapes[i] = .{
            try testCount(&db, "SELECT count(*) FROM intervals"),
            try testCount(&db, "SELECT sum(start_ms % 1000003) FROM intervals"),
            try testCount(&db, "SELECT count(*) FROM postings"),
            try testCount(&db, "SELECT count(*) FROM notes"),
        };
        try std.testing.expect(shapes[i][0] > 100);
        try std.testing.expect(shapes[i][2] > 0);
        // Nothing open, and today's work ends before now.
        try std.testing.expectEqual(@as(i64, 0), try testCount(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL"));
        const last_end = try testCount(&db, "SELECT max(end_ms) FROM intervals");
        try std.testing.expect(last_end <= now and last_end > now - 3_600_000);
        try std.testing.expectError(error.NotEmpty, seed(&db, std.testing.allocator, .{ .lang = lang, .instance = "example", .now_ms = now, .zone = &zone }));
    }
    try std.testing.expectEqual(shapes[0], shapes[1]);
}
