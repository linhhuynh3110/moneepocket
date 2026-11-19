// ===========================================================================
// MoneePocket - COIT20270 Assessment 4
// Thi My Linh Huynh (12291057)
//
// A budgeting app for international students who work part-time in
// Australia: see what is safe to spend, set limits per category, split
// household bills with housemates and review where the money went.
// ===========================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
// APP
//
// Entry point. main() loads the saved account, then MoneePocketApp puts the
// one MoneePocketStore above MaterialApp.router (Provider), so every
// route, dialog and sheet can reach the store.
// ============================================================

Future<void> main() async {  // load saved data, then start the app
  WidgetsFlutterBinding.ensureInitialized();
  final MoneePocketStore store = MoneePocketStore(MoneePocketServer());
  await store.load();
  runApp(MoneePocketApp(store: store));
}

class MoneePocketApp extends StatefulWidget {  // root widget: provides the store and the router
  const MoneePocketApp({super.key, required this.store});

  final MoneePocketStore store;

  @override
  State<MoneePocketApp> createState() => _MoneePocketAppState();
}

class _MoneePocketAppState extends State<MoneePocketApp> {  // keeps one router for the whole app
  late final GoRouter _router = buildMoneePocketRouter();

  @override
  void dispose() {
    _router.dispose();
    widget.store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<MoneePocketStore>.value(
      value: widget.store,
      child: MaterialApp.router(
        title: 'MoneePocket',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const _DragScrollBehavior(),
        theme: moneePocketTheme(Brightness.light),
        darkTheme: moneePocketTheme(Brightness.dark),
        routerConfig: _router,
      ),
    );
  }
}

// ============================================================
// STATE MANAGEMENT
//
// MoneePocketStore (ChangeNotifier) is the single source of truth. Screens
// call its methods; every method ends in _commit(), which recalculates
// Spent from the payments, calls notifyListeners() and schedules a save.
// MoneePocketScope is how widgets watch (of) or read (read) it via Provider.
// ============================================================

class MoneePocketStore extends ChangeNotifier {  // single source of truth for all app data
  MoneePocketStore(this._server);

  final MoneePocketServer _server;
  Timer? _pendingSave;

  String displayName = '';

  double accountBalanceAud = 0;

  double expectedFundsAud = 0;

  int paydayWeekday = DateTime.thursday;

  String? linkedBankName;
  bool shareSummaryWithFamily = false;
  bool useDisplayNameWithHousemates = true;
  bool hasSeenSwipeHint = false;

  final List<CategoryBudget> categoryBudgets = <CategoryBudget>[];

  final List<Expense> expenses = <Expense>[];

  String sharedBillDescription = '';
  double sharedBillTotalAud = 0;
  String? sharedBillReceiptName;
  SplitMethod splitMethod = SplitMethod.equal;
  DateTime? sharesSentAt;
  final List<HousemateShare> housemateShares = <HousemateShare>[];

  int sharesRevision = 0;

  bool get persistsBetweenRestarts => _server.persistsBetweenRestarts;

  Future<void> load() async {  // fetch the saved account when the app starts
    await _server.connect();
    _applyJson(await _server.fetchAccount());
    _recalculateSpending();
    notifyListeners();
    await _server.saveAccount(toJson());
  }

  void _commit() {  // recalculate, notify screens, then save
    _recalculateSpending();
    notifyListeners();
    _pendingSave?.cancel();
    _pendingSave = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_server.saveAccount(toJson())),
    );
  }

  @override
  void dispose() {
    _pendingSave?.cancel();
    super.dispose();
  }

  Map<String, Object?> toJson() => <String, Object?>{  // turn the whole account into JSON
    'displayName': displayName,
    'accountBalanceAud': accountBalanceAud,
    'expectedFundsAud': expectedFundsAud,
    'paydayWeekday': paydayWeekday,
    'budgets': <Object?>[
      for (final CategoryBudget budget in categoryBudgets) budget.toJson(),
    ],
    'expenses': <Object?>[
      for (final Expense expense in expenses) expense.toJson(),
    ],
    'bill': <String, Object?>{
      'description': sharedBillDescription,
      'totalAud': sharedBillTotalAud,
      'receiptName': sharedBillReceiptName,
      'splitMethod': splitMethod.name,
      'sentAt': sharesSentAt?.toIso8601String(),
      'shares': <Object?>[
        for (final HousemateShare share in housemateShares) share.toJson(),
      ],
    },
    'linkedBankName': linkedBankName,
    'privacy': <String, Object?>{
      'shareSummaryWithFamily': shareSummaryWithFamily,
      'useDisplayNameWithHousemates': useDisplayNameWithHousemates,
    },
    'hasSeenSwipeHint': hasSeenSwipeHint,
  };

  void _applyJson(Map<String, Object?> json) {  // fill the store from saved JSON
    List<Map<String, Object?>> listOf(Object? value) => <Map<String, Object?>>[
      for (final Object? item in (value as List<Object?>? ?? <Object?>[]))
        item! as Map<String, Object?>,
    ];
    final Map<String, Object?> bill =
        json['bill'] as Map<String, Object?>? ?? <String, Object?>{};
    final Map<String, Object?> privacy =
        json['privacy'] as Map<String, Object?>? ?? <String, Object?>{};

    displayName = json['displayName'] as String? ?? '';
    accountBalanceAud =
        (json['accountBalanceAud'] as num? ??
                json['availableFundsAud'] as num? ??
                0)
            .toDouble();
    expectedFundsAud = (json['expectedFundsAud'] as num? ?? 0).toDouble();
    paydayWeekday = json['paydayWeekday'] as int? ?? DateTime.thursday;
    linkedBankName = json['linkedBankName'] as String?;
    hasSeenSwipeHint = json['hasSeenSwipeHint'] as bool? ?? false;
    shareSummaryWithFamily =
        privacy['shareSummaryWithFamily'] as bool? ?? false;
    useDisplayNameWithHousemates =
        privacy['useDisplayNameWithHousemates'] as bool? ?? true;

    categoryBudgets
      ..clear()
      ..addAll(listOf(json['budgets']).map(CategoryBudget.fromJson));
    expenses
      ..clear()
      ..addAll(listOf(json['expenses']).map(Expense.fromJson))
      ..sort((Expense a, Expense b) => b.date.compareTo(a.date));

    sharedBillDescription = bill['description'] as String? ?? '';
    sharedBillTotalAud = (bill['totalAud'] as num? ?? 0).toDouble();
    sharedBillReceiptName = bill['receiptName'] as String?;
    splitMethod = SplitMethod.values.byName(
      bill['splitMethod'] as String? ?? SplitMethod.equal.name,
    );
    sharesSentAt = DateTime.tryParse(bill['sentAt'] as String? ?? '');
    housemateShares
      ..clear()
      ..addAll(listOf(bill['shares']).map(HousemateShare.fromJson));
    if (housemateShares.isEmpty) {
      housemateShares.add(HousemateShare(firstName: _selfName, amountAud: 0));
    }
    sharesRevision++;
  }

  String get _selfName => displayName.isEmpty ? 'Me' : displayName;

  void _recalculateSpending() {  // Spent is always calculated from payments
    final DateTime now = DateTime.now();
    for (final CategoryBudget budget in categoryBudgets) {
      for (final BudgetPeriod period in BudgetPeriod.values) {
        budget.spent[period] = spentBetween(
          budget.category,
          period.currentRange(now),
        );
      }
    }
  }

  double spentBetween(SpendingCategory? category, DateTimeRange range) =>  // total spent in a category and date range
      expensesBetween(
        category,
        range,
      ).fold<double>(0, (double sum, Expense e) => sum + e.amountAud);

  Iterable<Expense> expensesBetween(
    SpendingCategory? category,
    DateTimeRange range,
  ) => expenses.where(
    (Expense e) =>
        (category == null || e.category == category) &&
        !e.date.isBefore(range.start) &&
        e.date.isBefore(range.end),
  );

  List<PeriodBudget> budgetsFor(BudgetPeriod period) => <PeriodBudget>[  // every category's budget for one period
    for (final CategoryBudget budget in categoryBudgets) budget.of(period),
  ];

  double limitFor(BudgetPeriod period) => budgetsFor(  // total budget limit for one period
    period,
  ).fold<double>(0, (double sum, PeriodBudget b) => sum + b.limitAud);

  double spentIn(BudgetPeriod period) =>  // total spent in the current period
      spentBetween(null, period.currentRange(DateTime.now()));

  int daysLeftIn(BudgetPeriod period) =>  // days until the period resets
      daysBetween(DateTime.now(), period.currentRange(DateTime.now()).end);

  DateTime get nextPayday {
    final DateTime today = dateOnly(DateTime.now());
    final int daysAhead = (paydayWeekday - today.weekday) % 7;
    return today.add(Duration(days: daysAhead));
  }

  PeriodBudget budgetFor(  // one category's budget for one period
    SpendingCategory category, [
    BudgetPeriod period = BudgetPeriod.monthly,
  ]) => categoryBudgets
      .firstWhere((CategoryBudget budget) => budget.category == category)
      .of(period);

  PeriodBudget budgetToReport(SpendingCategory category) {  // budget shown after saving: over limit first
    final List<PeriodBudget> all = <PeriodBudget>[
      budgetFor(category),
      budgetFor(category, BudgetPeriod.weekly),
      budgetFor(category, BudgetPeriod.yearly),
    ];
    return all.firstWhere(
      (PeriodBudget b) => b.isOverLimit,
      orElse: () => all.firstWhere(
        (PeriodBudget b) => b.hasBudget,
        orElse: () => all.first,
      ),
    );
  }

  Expense? expenseById(String id) {  // find a payment by the id in the URL
    for (final Expense expense in expenses) {
      if (expense.id == id) return expense;
    }
    return null;
  }

  bool get limitsAreAffordable =>  // monthly limits fit the expected income
      limitFor(BudgetPeriod.monthly) <= expectedFundsAud;

  List<PeriodBudget> get overspentBudgets => budgetsFor(  // monthly budgets that are over the limit
    BudgetPeriod.monthly,
  ).where((PeriodBudget budget) => budget.isOverLimit).toList();

  bool get isBankLinked => linkedBankName != null;

  bool get sharesWereSent => sharesSentAt != null;

  bool get allSharesAgreed =>  // every housemate agreed to their share
      sharesWereSent &&
      housemateShares.every(
        (HousemateShare share) => share.response == ShareResponse.agreed,
      );

  SpendingCategory get sharedBillCategory => categoryBudgets
      .map((CategoryBudget budget) => budget.category)
      .firstWhere(
        (SpendingCategory c) => c == SpendingCategory.rentAndBills,
        orElse: () => categoryBudgets.first.category,
      );

  String exportAsText() => const JsonEncoder.withIndent('  ').convert(toJson());  // data export for Privacy and data

  String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  void recordExpense(Expense expense) {      // update the shared data
    expenses
      ..add(expense)
      ..sort((Expense a, Expense b) => b.date.compareTo(a.date));
    accountBalanceAud -= expense.amountAud;
    _commit();
  }

  void updateExpense(Expense updated) {  // edit a payment and adjust the balance
    final int index = expenses.indexWhere((Expense e) => e.id == updated.id);
    if (index < 0) return;
    accountBalanceAud += expenses[index].amountAud - updated.amountAud;
    expenses[index] = updated;
    expenses.sort((Expense a, Expense b) => b.date.compareTo(a.date));
    _commit();
  }

  int deleteExpense(Expense expense) {  // remove a payment; returns its index for Undo
    final int index = expenses.indexOf(expense);
    if (index < 0) return index;
    expenses.removeAt(index);
    accountBalanceAud += expense.amountAud;
    _commit();
    return index;
  }

  void restoreExpense(Expense expense, int index) {  // Undo: put the payment back in place
    expenses.insert(index.clamp(0, expenses.length), expense);
    accountBalanceAud -= expense.amountAud;
    _commit();
  }

  void markSwipeHintSeen() {  // show the swipe nudge only once
    hasSeenSwipeHint = true;
    _commit();
  }

  void updateBudget(  // change a category's limit for one period
    SpendingCategory category,
    BudgetPeriod period,
    double limitAud,
  ) {
    final CategoryBudget budget = categoryBudgets.firstWhere(
      (CategoryBudget b) => b.category == category,
    );
    if (limitAud > 0) {
      budget.limits[period] = limitAud;
    } else {
      budget.limits.remove(period);
    }
    _commit();
  }

  void setExpectedFunds(double amountAud) {  // expected income for the affordability check
    expectedFundsAud = amountAud;
    _commit();
  }

  void setPayday(int weekday) {
    paydayWeekday = weekday;
    _commit();
  }

  void addCategory(String label, BudgetPeriod period, double limitAud) {  // create a new budget category
    for (final CategoryBudget existing in categoryBudgets) {
      if (existing.category.label.toLowerCase() == label.toLowerCase()) {
        updateBudget(existing.category, period, limitAud);
        return;
      }
    }
    categoryBudgets.add(
      CategoryBudget(
        category: SpendingCategory(label, 'other'),
        limits: <BudgetPeriod, double>{period: limitAud},
      ),
    );
    _commit();
  }

  DeletedCategory deleteCategory(SpendingCategory category) {  // delete a category; returns it for Undo
    final int index = categoryBudgets.indexWhere(
      (CategoryBudget b) => b.category == category,
    );
    final List<Expense> payments = expenses
        .where((Expense e) => e.category == category)
        .toList();
    final DeletedCategory deleted = DeletedCategory(
      categoryBudgets.removeAt(index),
      index,
      payments,
    );
    expenses.removeWhere((Expense e) => e.category == category);
    accountBalanceAud += deleted.paymentsTotalAud;
    _commit();
    return deleted;
  }

  void restoreCategory(DeletedCategory deleted) {  // Undo: restore the category and its payments
    categoryBudgets.insert(
      deleted.index.clamp(0, categoryBudgets.length),
      deleted.budget,
    );
    expenses
      ..addAll(deleted.payments)
      ..sort((Expense a, Expense b) => b.date.compareTo(a.date));
    accountBalanceAud -= deleted.paymentsTotalAud;
    _commit();
  }

  void linkBankAccount(String bankName) {  // simulated bank link after consent
    linkedBankName = bankName;
    _commit();
  }

  void unlinkBankAccount() {  // remove the bank link
    linkedBankName = null;
    _commit();
  }

  void setDisplayName(String name) {  // name shown on Home and to housemates
    displayName = name.trim();
    housemateShares.first.firstName = _selfName;
    _commit();
  }

  void setPrivacyOption({bool? shareWithFamily, bool? useDisplayName}) {  // privacy switches on Privacy and data
    shareSummaryWithFamily = shareWithFamily ?? shareSummaryWithFamily;
    useDisplayNameWithHousemates =
        useDisplayName ?? useDisplayNameWithHousemates;
    _commit();
  }

  void deleteEverything() {  // delete my information: reset to an empty account
    _applyJson(<String, Object?>{
      'budgets': <Object?>[
        for (final SpendingCategory category in SpendingCategory.starterSet)
          CategoryBudget(category: category).toJson(),
      ],
      'hasSeenSwipeHint': true,
    });
    _commit();
  }

  void _billChanged() {  // bill edited: replies reset and shares recalculated
    if (sharesSentAt != null) {
      sharesSentAt = null;
      for (final HousemateShare share in housemateShares) {
        share.response = ShareResponse.waiting;
      }
    }
    if (splitMethod == SplitMethod.equal) _splitEqually();
    _commit();
  }

  void _splitEqually() {  // equal shares in cents; first person takes the remainder
    if (housemateShares.isEmpty) return;
    final int cents = (sharedBillTotalAud * 100).round();
    final int baseCents = cents ~/ housemateShares.length;
    final int remainder = cents - baseCents * housemateShares.length;
    for (int i = 0; i < housemateShares.length; i++) {
      housemateShares[i].amountAud =
          (baseCents + (i == 0 ? remainder : 0)) / 100;
    }
    sharesRevision++;
  }

  void setSplitMethod(SplitMethod method) {  // equal or custom split
    splitMethod = method;
    _billChanged();
  }

  void setBillTotal(double totalAud) {
    sharedBillTotalAud = totalAud;
    _billChanged();
  }

  void setBillDescription(String description) {
    sharedBillDescription = description;
    _commit();
  }

  void setBillReceipt(String? receiptName) {
    sharedBillReceiptName = receiptName;
    _commit();
  }

  void addHousemate(String firstName) {  // add a housemate to the bill
    housemateShares.add(HousemateShare(firstName: firstName, amountAud: 0));
    _billChanged();
  }

  void insertHousemate(int index, HousemateShare share) {  // Undo: put a removed housemate back
    housemateShares.insert(index.clamp(1, housemateShares.length), share);
    _billChanged();
  }

  void removeHousemate(int index) {  // swipe away a housemate
    if (index <= 0 || index >= housemateShares.length) return;
    housemateShares.removeAt(index);
    _billChanged();
  }

  void setCustomShare(int index, double amountAud) {  // custom amount from slider or text field
    housemateShares[index].amountAud = amountAud;
    _billChanged();
  }

  void sendSharesForAgreement() {  // send shares; my own share is agreed
    if (splitMethod == SplitMethod.equal) _splitEqually();
    for (final HousemateShare share in housemateShares) {
      share.response = ShareResponse.waiting;
    }
    housemateShares.first.response = ShareResponse.agreed;
    sharesSentAt = DateTime.now();
    _commit();
  }

  Future<void> refreshReplies() async {  // pull to refresh: get replies from the server
    final List<ShareResponse> replies = await _server.fetchReplies(
      housemateShares,
      sharesSentAt,
    );
    for (int i = 0; i < replies.length && i < housemateShares.length; i++) {
      housemateShares[i].response = replies[i];
    }
    _commit();
  }

  Expense recordSplit() {  // save only my share as a payment
    final Expense expense = Expense(
      id: newId(),
      description: sharedBillDescription,
      amountAud: housemateShares.first.amountAud,
      category: sharedBillCategory,
      date: DateTime.now(),
      receiptName: sharedBillReceiptName,
      isShared: true,
    );
    recordExpense(expense);
    resetBill();
    return expense;
  }

  void resetBill() {  // start a new empty bill
    sharedBillDescription = '';
    sharedBillTotalAud = 0;
    sharedBillReceiptName = null;
    splitMethod = SplitMethod.equal;
    sharesSentAt = null;
    housemateShares
      ..clear()
      ..add(HousemateShare(firstName: _selfName, amountAud: 0));
    sharesRevision++;
    _commit();
  }
}

class MoneePocketScope {  // short way for widgets to watch or read the store
  static MoneePocketStore of(BuildContext context) =>
      context.watch<MoneePocketStore>();      // watch context

  static MoneePocketStore read(BuildContext context) =>
      context.read<MoneePocketStore>();
}

// ============================================================
// PERSISTENCE - SIMULATED SERVER
//
// MoneePocketServer stands in for a backend: it saves the whole account as
// one JSON document with shared_preferences and returns seed data on first
// run (the only hard-coded data). Only MoneePocketStore calls it.
// ============================================================

class MoneePocketServer {  // simulated backend; only the store calls it
  static const String _accountKey = 'moneepocket.account.v5';

  static const List<String> supportedBanks = <String>[
    'Commonwealth Bank',
    'ANZ',
    'NAB',
    'Westpac',
    'ING',
    'Up',
  ];

  static const Duration replyDelay = Duration(seconds: 5);

  SharedPreferences? _prefs;
  String? _memoryCopy;

  bool get persistsBetweenRestarts => _prefs != null;

  Future<void> connect() async {  // open shared_preferences; falls back to memory
    try {
      _prefs = await SharedPreferences.getInstance().timeout(     // wait for store load
        const Duration(seconds: 3),
      );
    } on Object {
      _prefs = null;
    }
  }

  Future<Map<String, Object?>> fetchAccount() async {
    final String? stored = _prefs?.getString(_accountKey) ?? _memoryCopy;    // The load process reads the saved JSON
    if (stored == null) return _seedAccount(DateTime.now());
    try {
      return jsonDecode(stored) as Map<String, Object?>;
    } on FormatException {
      return _seedAccount(DateTime.now());
    }
  }

  Future<void> saveAccount(Map<String, Object?> account) async {            // restores the account data into the store
    _memoryCopy = jsonEncode(account);
    await _prefs?.setString(_accountKey, _memoryCopy!);
  }

  Future<List<ShareResponse>> fetchReplies(  // simulated housemate replies after a delay
    List<HousemateShare> shares,
    DateTime? sentAt,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final bool enoughTimePassed =
        sentAt != null && DateTime.now().difference(sentAt) >= replyDelay;
    return <ShareResponse>[
      for (final HousemateShare share in shares)
        share.response == ShareResponse.waiting && enoughTimePassed
            ? ShareResponse.agreed
            : share.response,
    ];
  }

  static Map<String, Object?> _seedAccount(DateTime now) {  // sample data used only on first run
    DateTime daysAgo(int days) =>
        DateTime(now.year, now.month, now.day - days, 12);
    DateTime thisMonth(int nominalDaysAgo) =>
        daysAgo((nominalDaysAgo * (now.day - 1) / 19).round());
    int nextId = 0;
    Expense paid(
      String description,
      double amount,
      SpendingCategory category,
      int days, {
      String? receipt,
      bool shared = false,
    }) => Expense(
      id: 'seed-${nextId++}',
      description: description,
      amountAud: amount,
      category: category,
      date: thisMonth(days),
      receiptName: receipt,
      isShared: shared,
    );

    final List<Expense> expenses = <Expense>[
      paid(
        'Coles Swanston St',
        42.15,
        SpendingCategory.groceries,
        0,
        receipt: 'receipt-coles.jpg',
      ),
      paid('Myki top up', 20.00, SpendingCategory.transport, 0),
      paid('Bánh mì with Mai', 11.50, SpendingCategory.eatingOut, 1),
      paid(
        'Electricity - my share',
        47.30,
        SpendingCategory.rentAndBills,
        2,
        shared: true,
      ),
      paid('Library printing', 6.80, SpendingCategory.study, 3),
      paid('Cinema Nova', 24.00, SpendingCategory.fun, 4),
      paid('Phone plan', 30.00, SpendingCategory.rentAndBills, 5),
      paid(
        'New bike tube',
        25.00,
        SpendingCategory.repairs,
        6,
        receipt: 'receipt-bike-shop.jpg',
      ),
      paid('Pharmacy', 12.50, SpendingCategory.health, 7),
      paid('Tram top up', 15.00, SpendingCategory.transport, 8),
      paid('Ramen with Sam', 18.90, SpendingCategory.eatingOut, 9),
      paid('Aldi weekly shop', 68.40, SpendingCategory.groceries, 10),
      paid('Pho with housemates', 32.60, SpendingCategory.eatingOut, 11),
      paid('Second-hand textbook', 27.20, SpendingCategory.study, 12),
      paid('Woolworths', 58.25, SpendingCategory.groceries, 13),
      paid('Rent - fortnight', 475.00, SpendingCategory.rentAndBills, 14),
      paid('Bubble tea', 7.80, SpendingCategory.eatingOut, 15),
      paid('Uber home after late shift', 27.75, SpendingCategory.transport, 16),
      paid('Queen Vic Market', 45.60, SpendingCategory.groceries, 17),
      paid('Karaoke night', 35.00, SpendingCategory.fun, 18),
      paid('Birthday dinner', 73.40, SpendingCategory.eatingOut, 19),
    ];

    CategoryBudget budget(
      SpendingCategory category,
      double monthly, {
      double? weekly,
      double? yearly,
    }) => CategoryBudget(
      category: category,
      limits: <BudgetPeriod, double>{
        if (weekly != null) BudgetPeriod.weekly: weekly,
        BudgetPeriod.monthly: monthly,
        if (yearly != null) BudgetPeriod.yearly: yearly,
      },
    );
    final List<CategoryBudget> budgets = <CategoryBudget>[
      budget(SpendingCategory.groceries, 320, weekly: 80),
      budget(SpendingCategory.eatingOut, 180, weekly: 45),
      budget(SpendingCategory.transport, 120, weekly: 30),
      budget(SpendingCategory.rentAndBills, 1000, yearly: 12000),
      budget(SpendingCategory.study, 90, yearly: 900),
      budget(SpendingCategory.fun, 150),
      budget(SpendingCategory.repairs, 80),
      budget(SpendingCategory.health, 60, yearly: 600),
    ];

    return <String, Object?>{
      'displayName': 'Asley',
      'accountBalanceAud': 1840.50,
      'expectedFundsAud': 2100.00,
      'paydayWeekday': DateTime.thursday,
      'budgets': <Object?>[
        for (final CategoryBudget budget in budgets) budget.toJson(),
      ],
      'expenses': <Object?>[
        for (final Expense expense in expenses) expense.toJson(),
      ],
      'bill': <String, Object?>{
        'description': 'Gas bill',
        'totalAud': 189.20,
        'receiptName': null,
        'splitMethod': SplitMethod.equal.name,
        'sentAt': now.toIso8601String(),
        'shares': <Object?>[
          HousemateShare(
            firstName: 'Asley',
            amountAud: 63.08,
            response: ShareResponse.agreed,
          ).toJson(),
          HousemateShare(firstName: 'Mai', amountAud: 63.06).toJson(),
          HousemateShare(
            firstName: 'Sam',
            amountAud: 63.06,
            response: ShareResponse.queried,
          ).toJson(),
        ],
      },
      'linkedBankName': null,
      'privacy': <String, Object?>{
        'shareSummaryWithFamily': false,
        'useDisplayNameWithHousemates': true,
      },
      'hasSeenSwipeHint': false,
    };
  }
}

// ============================================================
// NAVIGATION AND ROUTING
//
// GoRouter maps URLs to screens. A StatefulShellRoute gives Home, Budget,
// Split and Summary their own navigator, so each keeps its place; full-
// screen tasks (/add, /saved/:id, /expense/:id) sit on the root navigator.
// Section lists the four destinations shown in the navigation bar or rail.
//
// The four destinations and the pages inside them:
//   Home     /home     budget gauge, balance, top-5 chart, latest payments
//                      -> /home/transactions, /home/privacy, /home/link-bank
//   Budget   /budget   Weekly / Monthly / Yearly tabs: each category's
//                      budget, spent and remaining
//   Split    /split    divide a household bill between housemates
//                      -> /split/status (replies, record my share)
//   Summary  /summary  This week / month / year: Budget - Spent =
//                      Remaining, chart, categories by spending
//                      -> /summary/category/:index (one category's payments)
//
// Full-screen pages, opened from any destination:
//   /add               record a new payment
//   /saved/:id         confirmation and what is left in the budget
//   /expense/:id       view, edit (/expense/:id/edit) or delete a payment
// ============================================================

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

GoRouter buildMoneePocketRouter() {
  return GoRouter(                             // Manage centrally with GoRouter
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/home',                 // Navigation "Home"
    routes: <RouteBase>[
      StatefulShellRoute(
        builder:
            (
              BuildContext context,
              GoRouterState state,
              StatefulNavigationShell navigationShell,
            ) => AdaptiveNavigationScaffold(navigationShell: navigationShell),
        navigatorContainerBuilder:
            (
              BuildContext context,
              StatefulNavigationShell navigationShell,
              List<Widget> children,
            ) => FadingSectionStack(
              currentIndex: navigationShell.currentIndex,
              children: children,
            ),
        branches: <StatefulShellBranch>[
          _section('/home', const HomeDashboardScreen(), <RouteBase>[          // Full-screen tasks
            _page('transactions', (_) => const AllTransactionsScreen()),
            _page(
              'privacy',
              (_) => const PrivacyControlsScreen(),
              onRoot: true,
            ),
            _page('link-bank', (_) => const BankLinkScreen(), onRoot: true),
          ]),
          _section('/budget', const BudgetSetupScreen()),
          _section('/split', const SharedBillSplitScreen(), <RouteBase>[
            _page('status', (_) => const SplitStatusScreen()),
          ]),
          _section('/summary', const SpendingSummaryScreen(), <RouteBase>[
            _page(
              'category/:index',
              (GoRouterState state) => CategoryDetailScreen(
                index: int.tryParse(state.pathParameters['index']!) ?? 0,
                range:
                    BudgetPeriod.values
                        .asNameMap()[state.uri.queryParameters['range']] ??
                    BudgetPeriod.monthly,
              ),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/add',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (BuildContext context, GoRouterState state) =>
            growFromActionPage(state, const AddExpenseScreen()),
      ),
      _page(
        '/saved/:id',
        (GoRouterState state) =>
            ExpenseSavedScreen(expenseId: state.pathParameters['id']!),
        onRoot: true,
      ),
      _page(
        '/expense/:id',                                                       // /expense/:id carries the payment ID, and the destination screen uses that ID to get the correct Expense from MoneePocketStore.
        (GoRouterState state) =>
            ExpenseDetailScreen(expenseId: state.pathParameters['id']!),
        onRoot: true,
      ),
      _page(
        '/expense/:id/edit',
        (GoRouterState state) =>
            AddExpenseScreen(editId: state.pathParameters['id']),
        onRoot: true,
      ),
    ],
  );
}

StatefulShellBranch _section(  // one destination with its own navigator
  String path,
  Widget screen, [
  List<RouteBase> pages = const <RouteBase>[],
]) => StatefulShellBranch(
  routes: <RouteBase>[
    GoRoute(
      path: path,
      builder: (BuildContext context, GoRouterState state) => screen,
      routes: pages,
    ),
  ],
);

GoRoute _page(  // detail page using the shared transition
  String path,
  Widget Function(GoRouterState state) screen, {
  bool onRoot = false,
}) => GoRoute(
  path: path,
  parentNavigatorKey: onRoot ? _rootNavigatorKey : null,
  pageBuilder: (BuildContext context, GoRouterState state) =>
      sharedAxisPage(state, screen(state)),
);

enum Section {  // the four destinations in the bar or rail
  home('Home', Icons.home_outlined, Icons.home),
  budget('Budget', Icons.pie_chart_outline, Icons.pie_chart),
  split('Split', Icons.group_outlined, Icons.group),
  summary('Summary', Icons.insights_outlined, Icons.insights);

  const Section(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

// ============================================================
// GESTURES
//
// A payment row is wrapped in Dismissible: swipe left deletes (with Undo),
// swipe right opens details; a one-off nudge teaches the gesture.
// _DragScrollBehavior lets a mouse or trackpad drag lists and tabs too.
// Other gestures live in their screens: swipe a housemate away, pull to
// refresh split replies, swipe between tabs, drag sliders and sheets.
// ============================================================

class ExpenseListTile extends StatelessWidget {  // one payment row; tap opens its details
  const ExpenseListTile({super.key, required this.expense});

  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return ListTile(
      leading: CategoryAvatar(category: expense.category),
      title: Text(expense.description, style: text.titleMedium),
      subtitle: Text(
        '${expense.category.label} · ${expense.whenLabel}'
        '${expense.isShared ? ' · shared bill' : ''}',
      ),
      trailing: Text(
        formatAud(expense.amountAud),
        style: text.titleMedium?.copyWith(color: colors.tertiary),
      ),
      onTap: () => context.push('/expense/${expense.id}'),
    );
  }
}

class SwipeableExpenseTile extends StatelessWidget {             //adds gesture interaction around the reusable ExpenseListTile
  const SwipeableExpenseTile({
    super.key,
    required this.expense,                                      // receives an Expense from the screen
    this.showSwipeHint = false,
  });

  final Expense expense;
  final bool showSwipeHint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget deleteBackground = _SwipeBackground(
      color: colors.errorContainer,
      foreground: colors.onErrorContainer,
      icon: Icons.delete_outline,
      label: 'Delete',                                        // left swipe sends the delete action
      alignment: Alignment.centerRight,
    );
    final Widget tile = ExpenseListTile(expense: expense);

    return Dismissible(
      key: ValueKey<String>(expense.id),
      background: _SwipeBackground(
        color: colors.secondaryContainer,
        foreground: colors.onSecondaryContainer,
        icon: Icons.open_in_new,
        label: 'Details',                                   // right swipe uses Expense ID to navigate its details
        alignment: Alignment.centerLeft,
      ),
      secondaryBackground: deleteBackground,
      confirmDismiss: (DismissDirection direction) async {
        if (direction == DismissDirection.startToEnd) {
          context.push('/expense/${expense.id}');             // uses the Expense ID to navigate to its details
          return false;
        }
        return true;                                         // The store remains responsible for changing the data.
      },
      onDismissed: (_) => deleteExpenseWithUndo(context, expense),
      child: showSwipeHint
          ? _SwipeHint(
              background: deleteBackground,
              onFinished: () =>
                  MoneePocketScope.read(context).markSwipeHintSeen(),
              child: tile,
            )
          : tile,
    );
  }
}

class _SwipeBackground extends StatelessWidget {  // coloured background shown behind a swiped row
  const _SwipeBackground({
    required this.color,
    required this.foreground,
    required this.icon,
    required this.label,
    required this.alignment,
  });

  final Color color;
  final Color foreground;
  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: foreground),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: foreground)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwipeHint extends StatefulWidget {  // one-time nudge that teaches the swipe
  const _SwipeHint({
    required this.child,
    required this.background,
    required this.onFinished,
  });

  final Widget child;
  final Widget background;
  final VoidCallback onFinished;

  @override
  State<_SwipeHint> createState() => _SwipeHintState();
}

class _SwipeHintState extends State<_SwipeHint>  // slides the row a little, then back
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-0.25, 0),
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(const Duration(milliseconds: 1200), _play);
  }

  Future<void> _play() async {
    await _controller.forward();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onFinished();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: widget.background),
        SlideTransition(
          position: _offset,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

void deleteExpenseWithUndo(BuildContext context, Expense expense) {  // delete through the store and offer Undo
  final MoneePocketStore store = MoneePocketScope.read(context);
  final int index = store.deleteExpense(expense);
  showBriefMessage(
    context,
    '${expense.description} deleted',
    actionLabel: 'Undo',
    onAction: () => store.restoreExpense(expense, index),
  );
}

class _DragScrollBehavior extends MaterialScrollBehavior {  // lets mouse and trackpad drag lists and tabs
  const _DragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

// ============================================================
// TRANSITIONS
//
// Every route and tab change uses kTransitionDuration (900 ms). Detail
// pages rise and fade in (sharedAxisPage), Add spending grows from its
// button (growFromActionPage) and sections cross-fade (FadingSectionStack).
// ============================================================

const Duration kTransitionDuration = Duration(milliseconds: 900);  // setting to 900 milliseconds so the transitions are clearly visible for this app

CustomTransitionPage<void> sharedAxisPage(GoRouterState state, Widget child) {      // handles detail routes
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: kTransitionDuration,
    reverseTransitionDuration: kTransitionDuration,
    transitionsBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final CurvedAnimation curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.08),
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
                child: child,
              ),
            ),
          );
        },
  );
}

CustomTransitionPage<void> growFromActionPage(  // Add spending grows from its button
  GoRouterState state,
  Widget child,
) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    fullscreenDialog: true,
    transitionDuration: kTransitionDuration,
    reverseTransitionDuration: kTransitionDuration,
    transitionsBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final CurvedAnimation curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubicEmphasized,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              alignment: Alignment.bottomRight,
              scale: curved,
              child: child,
            ),
          );
        },
  );
}

class FadingSectionStack extends StatelessWidget {         //Handles movement between the four main sections
  const FadingSectionStack({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (int i = 0; i < children.length; i++)
          IgnorePointer(
            ignoring: i != currentIndex,
            child: ExcludeFocus(
              excluding: i != currentIndex,
              child: ExcludeSemantics(
                excluding: i != currentIndex,
                child: AnimatedOpacity(
                  opacity: i == currentIndex ? 1 : 0,
                  duration: kTransitionDuration,
                  curve: Curves.easeInOut,
                  child: TickerMode(
                    enabled: i == currentIndex,
                    child: children[i],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ============================================================
// RESPONSIVE AND ADAPTIVE LAYOUT
//
// WindowSizeClass turns the window width into compact / medium / expanded.
// AdaptiveNavigationScaffold shows a bottom bar, a rail or an extended
// rail to match; ReadableWidth stops content stretching on wide windows.
// Home, Budget and Summary add a second pane or column when there is room.
// ============================================================

enum WindowSizeClass { compact, medium, expanded }  // canonical Material 3 breakpoints

WindowSizeClass windowSizeClassOf(double width) {      //Under 600 is compact, under 840 is medium, and otherwise it is expanded.
  if (width < 600) return WindowSizeClass.compact;
  if (width < 840) return WindowSizeClass.medium;
  return WindowSizeClass.expanded;
}

class AdaptiveNavigationScaffold extends StatelessWidget {    // AdaptiveNavigationScaffold receives the navigation shell from GoRouter.
  const AdaptiveNavigationScaffold({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  Section get _current => Section.values[navigationShell.currentIndex];

  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final bool showAddSpending =
        _current == Section.home || _current == Section.summary;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final WindowSizeClass sizeClass = windowSizeClassOf(
          constraints.maxWidth,
        );
        final bool compact = sizeClass == WindowSizeClass.compact;

        return Scaffold(
          body: compact                         // Larger layouts use NavigationRail.
              ? navigationShell
              : Row(
                  children: <Widget>[
                    NavigationRail(
                      extended: sizeClass == WindowSizeClass.expanded,
                      selectedIndex: navigationShell.currentIndex,
                      onDestinationSelected: _select,
                      labelType: sizeClass == WindowSizeClass.medium
                          ? NavigationRailLabelType.all
                          : null,
                      destinations: <NavigationRailDestination>[
                        for (final Section section in Section.values)
                          NavigationRailDestination(
                            icon: Icon(section.icon),
                            selectedIcon: Icon(section.selectedIcon),
                            label: Text(section.label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: navigationShell),
                  ],
                ),
          floatingActionButton: showAddSpending
              ? FloatingActionButton.extended(
                  onPressed: () => context.push('/add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add spending'),
                )
              : null,
          bottomNavigationBar: compact                 //Compact layouts use the bottom NavigationBar
              ? NavigationBar(
                  selectedIndex: navigationShell.currentIndex,
                  onDestinationSelected: _select,
                  destinations: <NavigationDestination>[
                    for (final Section section in Section.values)
                      NavigationDestination(
                        icon: Icon(section.icon),
                        selectedIcon: Icon(section.selectedIcon),
                        label: section.label,
                      ),
                  ],
                )
              : null,
        );
      },
    );
  }
}

class ReadableWidth extends StatelessWidget {                  // ReadableWidth then helps keep content comfortable to read when more horizontal space is available.
  const ReadableWidth({super.key, required this.child, this.maxWidth = 720});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

// ============================================================
// THEME
//
// The look of the app, defined once. BrandColors is the palette (teal
// primary, coral for spending, mist, peach, cream background);
// moneePocketTheme builds the light and dark Material 3 themes from it.
// Screens take colours and text styles from Theme.of(context) only.
// ============================================================

abstract final class BrandColors {
  static const Color teal = Color(0xFF034C5F);
  static const Color coral = Color(0xFFEE6457);
  static const Color coralText = Color(0xFFBF4236);
  static const Color mist = Color(0xFF97BEC6);
  static const Color peach = Color(0xFFF9C4BA);
  static const Color cream = Color(0xFFFDF5F4);
}

ThemeData moneePocketTheme(Brightness brightness) {  // builds the Material 3 theme from BrandColors
  final bool light = brightness == Brightness.light;
  final ColorScheme colors = ColorScheme.fromSeed(
    seedColor: BrandColors.teal,
    brightness: brightness,
    primary: light ? BrandColors.teal : BrandColors.mist,
    tertiary: light ? BrandColors.coralText : const Color(0xFFFF8A7D),
    secondaryContainer: light ? BrandColors.mist.withValues(alpha: 0.45) : null,
    tertiaryContainer: light ? BrandColors.peach : null,
    surface: light ? BrandColors.cream : null,
    surfaceContainerLow: light ? const Color(0xFFFBF0EE) : null,
    surfaceContainer: light ? const Color(0xFFF8ECE9) : null,
    surfaceContainerHigh: light ? const Color(0xFFF4E6E2) : null,
    surfaceContainerHighest: light ? const Color(0xFFEFE0DC) : null,
  );
  final TextTheme base = ThemeData(colorScheme: colors).textTheme.apply(
    bodyColor: colors.onSurface,
    displayColor: colors.onSurface,
  );
  return ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    textTheme: base.copyWith(
      displaySmall: base.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: base.bodyMedium?.copyWith(letterSpacing: 0.2),
      bodySmall: base.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      labelSmall: base.labelSmall?.copyWith(color: colors.onSurfaceVariant),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      surfaceTintColor: colors.surface,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
    ),
  );
}

// ============================================================
// MONEY MODEL (DATA CLASSES)
//
// Plain data classes with toJson/fromJson that the store holds:
// categories, payments, budgets (one limit per weekly/monthly/yearly
// period) and split-bill shares. No UI and no storage code.
//
// Five figures are kept separate:
//   Account balance  what the user has now; changes only when a payment
//                    is recorded, edited, deleted or restored
//   Budget           a limit for a category and period; a plan, not money
//   Spent            total of payments in the period; always calculated
//                    from the payment list, never stored
//   Remaining        Budget - Spent
//   Expected income  planned monthly income; only checks affordability
// ============================================================

@immutable
class SpendingCategory {  // a spending category: label, icon and colour
  const SpendingCategory(this.label, this.iconKey);

  final String label;
  final String iconKey;

  IconData get icon => iconsByKey[iconKey] ?? Icons.category_outlined;

  bool get isCustom => !starterSet.contains(this);

  Color get color {
    final int index = iconsByKey.keys.toList().indexOf(iconKey);
    return chartPalette[(index >= 0 && iconKey != 'other'
            ? index
            : label.hashCode.abs()) %
        chartPalette.length];
  }

  static const List<Color> chartPalette = <Color>[
    Color(0xFF034C5F),
    Color(0xFFEE6457),
    Color(0xFF5B9AA9),
    Color(0xFFD9897A),
    Color(0xFF2E7D6B),
    Color(0xFFC9A227),
    Color(0xFF7A5C99),
    Color(0xFF8C6E5A),
  ];

  static const Map<String, IconData> iconsByKey = <String, IconData>{
    'groceries': Icons.local_grocery_store_outlined,
    'eatingOut': Icons.restaurant_outlined,
    'transport': Icons.directions_bus_outlined,
    'rent': Icons.home_outlined,
    'study': Icons.menu_book_outlined,
    'fun': Icons.celebration_outlined,
    'repairs': Icons.build_outlined,
    'health': Icons.medical_services_outlined,
    'other': Icons.category_outlined,
  };

  static const SpendingCategory groceries = SpendingCategory(
    'Groceries',
    'groceries',
  );
  static const SpendingCategory eatingOut = SpendingCategory(
    'Eating out',
    'eatingOut',
  );
  static const SpendingCategory transport = SpendingCategory(
    'Transport',
    'transport',
  );
  static const SpendingCategory rentAndBills = SpendingCategory(
    'Rent and bills',
    'rent',
  );
  static const SpendingCategory study = SpendingCategory('Study', 'study');
  static const SpendingCategory fun = SpendingCategory('Going out', 'fun');
  static const SpendingCategory repairs = SpendingCategory(
    'Repairs (bike)',
    'repairs',
  );
  static const SpendingCategory health = SpendingCategory('Health', 'health');

  static const List<SpendingCategory> starterSet = <SpendingCategory>[
    groceries,
    eatingOut,
    transport,
    rentAndBills,
    study,
    fun,
    repairs,
    health,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'icon': iconKey,
  };

  factory SpendingCategory.fromJson(Map<String, Object?> json) =>
      SpendingCategory(
        json['label']! as String,
        json['icon'] as String? ?? 'other',
      );

  @override
  bool operator ==(Object other) =>
      other is SpendingCategory && other.label == label;

  @override
  int get hashCode => label.hashCode;
}

enum BudgetPeriod {  // weekly, monthly or yearly budget cycle
  weekly('Weekly', 'week', 500),
  monthly('Monthly', 'month', 2000),
  yearly('Yearly', 'year', 20000);

  const BudgetPeriod(this.label, this.noun, this.sliderMaxAud);

  final String label;
  final String noun;

  final double sliderMaxAud;

  DateTimeRange currentRange(DateTime today) => switch (this) {
    BudgetPeriod.weekly => DateTimeRange(
      start: DateTime(today.year, today.month, today.day - today.weekday + 1),
      end: DateTime(today.year, today.month, today.day - today.weekday + 8),
    ),
    BudgetPeriod.monthly => DateTimeRange(
      start: DateTime(today.year, today.month),
      end: DateTime(today.year, today.month + 1),
    ),
    BudgetPeriod.yearly => DateTimeRange(
      start: DateTime(today.year),
      end: DateTime(today.year + 1),
    ),
  };
}

String formatRange(DateTimeRange range) =>  // date range as text, e.g. 1 Oct - 31 Oct
    '${formatDayMonth(range.start)} - '
    '${formatDayMonth(range.end.subtract(const Duration(days: 1)))}';

@immutable
class Expense {  // one payment; saved with toJson/fromJson
  const Expense({
    required this.id,
    required this.description,
    required this.amountAud,
    required this.category,
    required this.date,
    this.receiptName,
    this.isShared = false,
  });

  final String id;
  final String description;
  final double amountAud;
  final SpendingCategory category;
  final DateTime date;
  final String? receiptName;
  final bool isShared;

  bool get hasReceipt => receiptName != null;

  String get whenLabel {
    final int days = daysBetween(date, DateTime.now());
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return '$days days ago';
    return formatDayMonth(date);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'description': description,
    'amountAud': amountAud,
    'category': category.toJson(),
    'date': date.toIso8601String(),
    'receiptName': receiptName,
    'isShared': isShared,
  };

  factory Expense.fromJson(Map<String, Object?> json) => Expense(
    id: json['id']! as String,
    description: json['description']! as String,
    amountAud: (json['amountAud']! as num).toDouble(),
    category: SpendingCategory.fromJson(
      json['category']! as Map<String, Object?>,
    ),
    date: DateTime.parse(json['date']! as String),
    receiptName: json['receiptName'] as String?,
    isShared: json['isShared'] as bool? ?? false,
  );
}

@immutable
class PeriodBudget {  // limit and spent for one category in one period
  const PeriodBudget(this.category, this.period, this.limitAud, this.spentAud);

  final SpendingCategory category;
  final BudgetPeriod period;
  final double limitAud;
  final double spentAud;

  double get remainingAud => limitAud - spentAud;

  double get usedFraction =>  // share of the limit used, from 0 to 1, for bars
      limitAud <= 0 ? 0 : (spentAud / limitAud).clamp(0.0, 1.0).toDouble();

  bool get hasBudget => limitAud > 0;  // a limit above zero has been set

  bool get isOverLimit => hasBudget && spentAud > limitAud;  // spent more than the limit

  double get overByAud => spentAud - limitAud;
}

class CategoryBudget {  // a category with its limit for each period
  CategoryBudget({required this.category, Map<BudgetPeriod, double>? limits})
    : limits = limits ?? <BudgetPeriod, double>{};

  final SpendingCategory category;
  final Map<BudgetPeriod, double> limits;
  final Map<BudgetPeriod, double> spent = <BudgetPeriod, double>{};

  PeriodBudget of(BudgetPeriod period) =>
      PeriodBudget(category, period, limits[period] ?? 0, spent[period] ?? 0);

  Map<String, Object?> toJson() => <String, Object?>{
    'category': category.toJson(),
    'limits': <String, Object?>{
      for (final MapEntry<BudgetPeriod, double> e in limits.entries)
        e.key.name: e.value,
    },
  };

  factory CategoryBudget.fromJson(Map<String, Object?> json) => CategoryBudget(
    category: SpendingCategory.fromJson(
      json['category']! as Map<String, Object?>,
    ),
    limits: <BudgetPeriod, double>{
      for (final MapEntry<String, Object?> e
          in (json['limits'] as Map<String, Object?>? ?? <String, Object?>{})
              .entries)
        if (BudgetPeriod.values.asNameMap()[e.key] != null)
          BudgetPeriod.values.byName(e.key): (e.value! as num).toDouble(),
    },
  );
}

@immutable
class DeletedCategory {  // kept so Undo can restore a deleted category
  const DeletedCategory(this.budget, this.index, this.payments);

  final CategoryBudget budget;
  final int index;
  final List<Expense> payments;

  double get paymentsTotalAud =>
      payments.fold<double>(0, (double sum, Expense e) => sum + e.amountAud);
}

enum ShareResponse {  // a housemate's reply: waiting, agreed or declined
  waiting('Waiting', Icons.schedule),
  agreed('Agreed', Icons.check_circle_outline),
  queried('Asked to change', Icons.error_outline);

  const ShareResponse(this.label, this.icon);

  final String label;
  final IconData icon;
}

class HousemateShare {  // one person's share of a bill
  HousemateShare({
    required this.firstName,
    required this.amountAud,
    this.response = ShareResponse.waiting,
  });

  String firstName;
  double amountAud;
  ShareResponse response;

  Map<String, Object?> toJson() => <String, Object?>{
    'firstName': firstName,
    'amountAud': amountAud,
    'response': response.name,
  };

  factory HousemateShare.fromJson(Map<String, Object?> json) => HousemateShare(
    firstName: json['firstName']! as String,
    amountAud: (json['amountAud']! as num).toDouble(),
    response: ShareResponse.values.byName(json['response']! as String),
  );
}

enum SplitMethod { equal, custom }  // how the bill is divided

// ============================================================
// SHARED WIDGETS AND HELPERS
//
// Reusable pieces used by several screens: charts drawn with CustomPainter,
// the category avatar, amount input, dialogs, and the functions that
// format amounts and dates. They hold no app data themselves.
// ============================================================

class SectionHeader extends StatelessWidget {  // bold heading above a group of content
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: text.titleLarge),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: text.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class CategoryAvatar extends StatelessWidget {  // round icon in the category's colour
  const CategoryAvatar({super.key, required this.category, this.radius = 22});

  final SpendingCategory category;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: category.color,
      foregroundColor: Colors.white,
      child: Icon(category.icon, size: radius),
    );
  }
}

class BudgetGaugePainter extends CustomPainter {  // draws the half-circle budget gauge
  BudgetGaugePainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 14;
    const double pi = 3.14159265;
    final Rect arcBox = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.width - stroke,
    );
    Paint paintFor(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcBox, pi, pi, false, paintFor(track));
    if (fraction > 0) {
      canvas.drawArc(
        arcBox,
        pi,
        pi * fraction.clamp(0.0, 1.0),
        false,
        paintFor(fill),
      );
    }
  }

  @override
  bool shouldRepaint(BudgetGaugePainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill;
}

@immutable
class ChartSlice {  // one slice of the donut chart
  const ChartSlice(this.category, this.amountAud);

  final SpendingCategory category;
  final double amountAud;
}

class DonutChart extends StatelessWidget {  // donut chart of spending by category
  const DonutChart({
    super.key,
    required this.slices,
    required this.centre,
    this.size = 180,
  });

  final List<ChartSlice> slices;
  final Widget centre;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        key: ValueKey<int>(
          Object.hashAll(slices.map((ChartSlice s) => s.amountAud)),
        ),
        tween: Tween<double>(begin: 0, end: 1),
        duration: kTransitionDuration,
        curve: Curves.easeOutCubic,
        builder: (BuildContext context, double progress, Widget? child) =>
            CustomPaint(
              painter: _DonutPainter(
                slices: slices,
                progress: progress,
                empty: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: child,
            ),
        child: Center(child: centre),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {  // paints the donut slices
  _DonutPainter({
    required this.slices,
    required this.progress,
    required this.empty,
  });

  final List<ChartSlice> slices;
  final double progress;
  final Color empty;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 26;
    const double fullTurn = 6.2831853;
    const double gap = 0.03;
    final Rect box = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final double total = slices.fold<double>(
      0,
      (double sum, ChartSlice s) => sum + s.amountAud,
    );
    if (total <= 0) {
      canvas.drawArc(box, 0, fullTurn, false, paint..color = empty);
      return;
    }
    double start = -fullTurn / 4;
    for (final ChartSlice slice in slices) {
      final double sweep = fullTurn * slice.amountAud / total * progress;
      if (sweep > gap) {
        canvas.drawArc(
          box,
          start,
          sweep - gap,
          false,
          paint..color = slice.category.color,
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.slices != slices ||
      oldDelegate.empty != empty;
}

class BudgetBar extends StatelessWidget {  // progress bar: spent against the limit
  const BudgetBar({super.key, required this.budget, this.thickness = 8});

  final PeriodBudget budget;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LinearProgressIndicator(
        value: budget.usedFraction,
        minHeight: thickness,
        color: budget.isOverLimit ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

class StatusNote extends StatelessWidget {  // plain-language note; a problem is shown as a fact
  const StatusNote({super.key, required this.message, this.isProblem = false});

  final String message;
  final bool isProblem;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            isProblem ? Icons.info_outline : Icons.check_circle_outline,
            color: isProblem ? colors.error : colors.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

void showBriefMessage(  // snackbar with an optional action such as Undo
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
}

Future<bool> confirmAction(  // AlertDialog asking to confirm an action
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      icon: Icon(icon),
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class TextPromptDialog extends StatefulWidget {  // dialog with one text field, e.g. type DELETE
  const TextPromptDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.message,
    this.hint,
    this.initialText = '',
    this.mustEqual,
    this.cancelLabel = 'Cancel',
  });

  final IconData icon;
  final String title;
  final String label;
  final String confirmLabel;
  final String? message;
  final String? hint;
  final String initialText;
  final String? mustEqual;
  final String cancelLabel;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {  // validates the text before enabling the button
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canConfirm =>
      widget.mustEqual == null ||
      _controller.text.trim().toUpperCase() == widget.mustEqual;

  void _confirm() {
    if (_canConfirm) Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(widget.icon),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.message != null) ...<Widget>[
            Text(widget.message!),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _confirm(),
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: _canConfirm ? _confirm : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class AmountInput extends StatefulWidget {  // amount field paired with a slider
  const AmountInput({
    super.key,
    required this.title,
    required this.valueAud,
    required this.onChanged,
    this.leading,
    this.sliderMax,
    this.decimals = 0,
  });

  final Widget title;
  final double valueAud;
  final ValueChanged<double> onChanged;
  final Widget? leading;

  final double? sliderMax;
  final int decimals;

  @override
  State<AmountInput> createState() => _AmountInputState();
}

class _AmountInputState extends State<AmountInput> {  // keeps the slider and text field in sync
  late final TextEditingController _controller = TextEditingController(
    text: widget.valueAud.toStringAsFixed(widget.decimals),
  );
  final FocusNode _focus = FocusNode();
  String? _errorText;

  @override
  void didUpdateWidget(AmountInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus &&
        double.tryParse(_controller.text) != widget.valueAud) {
      _controller.text = widget.valueAud.toStringAsFixed(widget.decimals);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onText(String value) {
    final double? parsed = double.tryParse(value.trim());
    setState(
      () => _errorText = parsed == null || parsed < 0 ? 'Numbers only' : null,
    );
    if (_errorText == null) widget.onChanged(parsed!);
  }

  void _onSlider(double value) {
    widget.onChanged(value);
    _controller.text = value.toStringAsFixed(widget.decimals);
  }

  @override
  Widget build(BuildContext context) {
    final double? max = widget.sliderMax;
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            if (widget.leading != null) ...<Widget>[
              widget.leading!,
              const SizedBox(width: 12),
            ],
            Expanded(child: widget.title),
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.end,
                onChanged: _onText,
                decoration: InputDecoration(
                  prefixText: '\$ ',
                  isDense: true,
                  errorText: _errorText,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        if (max != null && max > 0)
          Slider(
            value: widget.valueAud.clamp(0, max).toDouble(),
            max: max,
            label: formatAud(widget.valueAud),
            onChanged: _onSlider,
          ),
      ],
    );
  }
}

Future<String?> chooseReceipt(BuildContext context, String prefix) {  // bottom sheet simulating a receipt photo
  final DateTime now = DateTime.now();
  final String stamp = '${now.day}-${_monthNames[now.month - 1].toLowerCase()}';
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('Scan a receipt'),
            onTap: () =>
                Navigator.of(sheetContext).pop('$prefix-scan-$stamp.jpg'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a photo'),
            onTap: () =>
                Navigator.of(sheetContext).pop('$prefix-photo-$stamp.jpg'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

const List<String> _monthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> _weekdayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String formatAud(double amount) {  // one money format for every screen
  final List<String> parts = amount.abs().toStringAsFixed(2).split('.');
  final String digits = parts[0];
  final StringBuffer grouped = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}\$$grouped.${parts[1]}';
}

String formatDayMonth(DateTime date) =>  // date as day and month
    '${date.day} ${_monthNames[date.month - 1]}';

String formatWeekday(int weekday) => _weekdayNames[weekday - 1];

DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

int daysBetween(DateTime from, DateTime to) =>
    (dateOnly(to).difference(dateOnly(from)).inHours / 24).round();

// ============================================================
// SCREENS
//
// One block per route, in navigation order: the four destinations (Home,
// Budget, Split, Summary) with the pages inside them, then the full-
// screen pages. Every screen watches MoneePocketStore in build() and
// calls its methods from callbacks; only unsaved form input is local
// state.
// ============================================================

// ------------------------------------------------------------
// SCREEN - HOME (/home)
//
// Monthly budget gauge, account balance, spending donut (top 5) and recent
// payments; two panes on wide windows. Watches the store.
// ------------------------------------------------------------

class HomeDashboardScreen extends StatelessWidget {  // Home: two panes when the body is 720 dp or wider
  const HomeDashboardScreen({super.key});

  List<Widget> _spaced(List<Widget> cards) => <Widget>[
    for (int i = 0; i < cards.length; i++) ...<Widget>[
      if (i > 0) const SizedBox(height: 16),
      cards[i],
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final String greeting = store.displayName.isEmpty
        ? 'Hi there'
        : 'Hi ${store.displayName}';

    final List<Widget> overview = _spaced(<Widget>[
      const BudgetSummaryCard(),
      const _BalanceCard(),
      const SpendingBreakdownCard(),
      if (!store.isBankLinked) const _LinkBankPrompt(),
    ]);
    const Widget recent = _RecentSpendingCard();

    return Scaffold(
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool twoPane = constraints.maxWidth >= 720;
          return CustomScrollView(
            slivers: <Widget>[
              SliverAppBar.large(
                title: Text(greeting),
                actions: <Widget>[
                  IconButton(
                    tooltip: 'Privacy and data',
                    icon: const Icon(Icons.shield_outlined),
                    onPressed: () => context.push('/home/privacy'),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: ReadableWidth(
                  maxWidth: twoPane ? 1200 : 720,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    child: twoPane
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                flex: 5,
                                child: Column(children: overview),
                              ),
                              const SizedBox(width: 24),
                              const Expanded(flex: 4, child: recent),
                            ],
                          )
                        : Column(
                            children: <Widget>[
                              ...overview,
                              const SizedBox(height: 16),
                              recent,
                            ],
                          ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class BudgetSummaryCard extends StatelessWidget {  // gauge with budget, spent and days left
  const BudgetSummaryCard({
    super.key,
    this.period = BudgetPeriod.monthly,
    this.action,
  });

  final BudgetPeriod period;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final double limit = store.limitFor(period);
    final double spent = store.spentIn(period);
    final double left = limit - spent;
    final bool over = left < 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            Text(
              '${period.label} budget',
              style: text.labelLarge?.copyWith(color: colors.primary),
            ),
            Text(
              formatRange(period.currentRange(DateTime.now())),
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: AspectRatio(
                aspectRatio: 1.8,
                child: CustomPaint(
                  painter: BudgetGaugePainter(
                    fraction: limit <= 0 ? 0 : spent / limit,
                    track: colors.surfaceContainerHighest,
                    fill: over ? colors.error : colors.primary,
                  ),
                  child: Align(
                    alignment: const Alignment(0, 0.5),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          over ? 'Over budget by' : 'Remaining',
                          style: text.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        FittedBox(
                          child: Text(
                            formatAud(left.abs()),
                            style: text.displaySmall?.copyWith(
                              color: over ? colors.error : colors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            IntrinsicHeight(
              child: Row(
                children: <Widget>[
                  _Figure(label: 'Budget', value: formatAud(limit)),
                  const VerticalDivider(),
                  _Figure(
                    label: 'Spent',
                    value: formatAud(spent),
                    color: colors.tertiary,
                  ),
                  const VerticalDivider(),
                  _Figure(
                    label: 'Until reset',
                    value: '${store.daysLeftIn(period)} days',
                  ),
                ],
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {  // one labelled number in a summary card
  const _Figure({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: <Widget>[
          FittedBox(
            child: Text(value, style: text.titleMedium?.copyWith(color: color)),
          ),
          Text(label, style: text.bodySmall),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {  // account balance, kept separate from the budget
  const _BalanceCard();

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final DateTime payday = store.nextPayday;
    final bool paidToday = daysBetween(DateTime.now(), payday) == 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: <Widget>[
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.secondaryContainer,
                foregroundColor: colors.onSecondaryContainer,
                child: const Icon(Icons.account_balance_wallet_outlined),
              ),
              title: const Text('Account balance'),
              subtitle: Text(
                paidToday
                    ? 'The money you have now · payday is today'
                    : 'The money you have now · next payday '
                          '${formatWeekday(payday.weekday)} '
                          '${formatDayMonth(payday)}',
              ),
              trailing: Text(
                formatAud(store.accountBalanceAud),
                style: text.titleMedium,
              ),
            ),
            for (final PeriodBudget budget in store.overspentBudgets)
              ListTile(
                dense: true,
                leading: Icon(Icons.error_outline, color: colors.error),
                title: Text(
                  '${budget.category.label} is ${formatAud(budget.overByAud)} '
                  'over its monthly budget',
                  style: text.bodyMedium?.copyWith(color: colors.error),
                ),
                subtitle: const Text('Nothing is blocked. Tap to adjust.'),
                onTap: () => context.go('/budget'),
              ),
          ],
        ),
      ),
    );
  }
}

class SpendingBreakdownCard extends StatefulWidget {  // donut of the top categories with a legend
  const SpendingBreakdownCard({super.key});

  @override
  State<SpendingBreakdownCard> createState() => _SpendingBreakdownCardState();
}

class _SpendingBreakdownCardState extends State<SpendingBreakdownCard> {  // top 5 categories, or all after See all
  static const int _shown = 5;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<PeriodBudget> budgets = store.budgetsFor(BudgetPeriod.monthly)
      ..sort(
        (PeriodBudget a, PeriodBudget b) => b.spentAud.compareTo(a.spentAud),
      );

    final Widget chart = DonutChart(
      slices: <ChartSlice>[
        for (final PeriodBudget budget in budgets)
          ChartSlice(budget.category, budget.spentAud),
      ],
      centre: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Spent', style: text.bodySmall),
          Text(
            formatAud(store.spentIn(BudgetPeriod.monthly)),
            style: text.titleMedium,
          ),
        ],
      ),
    );
    final Widget legend = Column(
      children: <Widget>[
        for (final PeriodBudget budget
            in _showAll ? budgets : budgets.take(_shown))
          _LegendRow(budget: budget),
        if (budgets.length > _shown)
          TextButton(
            onPressed: () => setState(() => _showAll = !_showAll),
            child: Text(_showAll ? 'Show less' : 'See all (${budgets.length})'),
          ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Where your monthly budget went', style: text.titleLarge),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (constraints.maxWidth < 520) {
                  return Column(
                    children: <Widget>[
                      chart,
                      const SizedBox(height: 16),
                      legend,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    chart,
                    const SizedBox(width: 24),
                    Expanded(child: legend),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {  // legend row; tap opens the category sheet
  const _LegendRow({required this.budget});

  final PeriodBudget budget;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => CategoryDetailSheet(category: budget.category),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: <Widget>[
            CategoryAvatar(category: budget.category, radius: 16),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          budget.category.label,
                          style: text.titleSmall,
                        ),
                      ),
                      Text(
                        budget.hasBudget
                            ? '${formatAud(budget.spentAud)} of '
                                  '${formatAud(budget.limitAud)}'
                            : '${formatAud(budget.spentAud)} · no budget',
                        style: text.bodySmall?.copyWith(
                          color: budget.isOverLimit
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  BudgetBar(budget: budget, thickness: 6),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _RecentSpendingCard extends StatelessWidget {  // latest payments as swipeable rows + See all
  const _RecentSpendingCard();

  static const int _shown = 5;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final List<Expense> latest = store.expenses.take(_shown).toList();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Recent spending',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (store.expenses.length > _shown)
                  TextButton(
                    onPressed: () => context.push('/home/transactions'),
                    child: Text('See all (${store.expenses.length})'),
                  ),
              ],
            ),
          ),
          if (latest.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Nothing recorded yet. Tap Add spending to record '
                'your first payment.',
              ),
            ),
          for (int i = 0; i < latest.length; i++)
            SwipeableExpenseTile(
              expense: latest[i],
              showSwipeHint: i == 0 && !store.hasSeenSwipeHint,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _LinkBankPrompt extends StatelessWidget {  // optional prompt to link a bank
  const _LinkBankPrompt();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Card.outlined(
      child: InkWell(
        onTap: () => context.push('/home/link-bank'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.account_balance_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Check your pay automatically',
                      style: text.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Link your bank so MoneePocket can match your part-time pay. '
                'You can use the app fully without linking.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => context.push('/home/link-bank'),
                child: const Text('See how it works'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CategoryDetailSheet extends StatelessWidget {  // bottom sheet with one category's budget
  const CategoryDetailSheet({super.key, required this.category});

  final SpendingCategory category;

  @override
  Widget build(BuildContext context) {
    final PeriodBudget budget = MoneePocketScope.of(
      context,
    ).budgetFor(category);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CategoryAvatar(category: category),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(category.label, style: text.headlineSmall),
                ),
              ],
            ),
            const SizedBox(height: 16),
            BudgetBar(budget: budget, thickness: 10),
            const SizedBox(height: 12),
            Text(
              '${formatAud(budget.spentAud)} spent of '
              '${formatAud(budget.limitAud)} this month',
              style: text.bodyLarge,
            ),
            Text(
              budget.isOverLimit
                  ? '${formatAud(budget.overByAud)} over this limit.'
                  : '${formatAud(budget.remainingAud)} remaining.',
              style: text.titleMedium?.copyWith(
                color: budget.isOverLimit ? colors.error : colors.primary,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  final GoRouter router = GoRouter.of(context);
                  Navigator.of(context).pop();
                  router.go('/budget');
                },
                child: const Text('Change limit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------
// SCREEN - ALL SPENDING (/home/transactions)
//
// Every payment, newest first, using the same swipeable rows.
// ------------------------------------------------------------

class AllTransactionsScreen extends StatelessWidget {  // every payment, newest first
  const AllTransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Map<DateTime, List<Expense>> byDay = <DateTime, List<Expense>>{};
    for (final Expense expense in store.expenses) {
      byDay.putIfAbsent(dateOnly(expense.date), () => <Expense>[]).add(expense);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('All spending')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: <Widget>[
            if (byDay.isEmpty) const Text('Nothing recorded yet.'),
            for (final MapEntry<DateTime, List<Expense>> day in byDay.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: Column(
                    children: <Widget>[
                      ListTile(
                        leading: Text(
                          day.key.day.toString().padLeft(2, '0'),
                          style: text.headlineMedium,
                        ),
                        title: Text(formatWeekday(day.key.weekday)),
                        subtitle: Text(
                          '${_monthNames[day.key.month - 1]} '
                          '${day.key.year}',
                        ),
                        trailing: Text(
                          formatAud(
                            day.value.fold<double>(
                              0,
                              (double sum, Expense e) => sum + e.amountAud,
                            ),
                          ),
                          style: text.titleMedium,
                        ),
                      ),
                      Divider(height: 1, color: colors.outlineVariant),
                      for (final Expense expense in day.value)
                        SwipeableExpenseTile(expense: expense),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------
// SCREEN - PRIVACY AND DATA (/home/privacy)
//
// Display name, data export and Delete my information.
// ------------------------------------------------------------

class PrivacyControlsScreen extends StatelessWidget {  // display name, privacy switches, export, delete
  const PrivacyControlsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy and data')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Where your information is kept',
                        style: text.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        store.persistsBetweenRestarts
                            ? 'Your payments and budgets are saved on this '
                                  'device only. Nothing is sold or shared unless '
                                  'you switch it on below.'
                            : 'This browser does not allow saving, so your '
                                  'changes last until you close the app.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SectionHeader(title: 'You'),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Display name'),
              subtitle: Text(
                store.displayName.isEmpty ? 'Not set' : store.displayName,
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editName(context, store),
            ),
            const SectionHeader(title: 'Sharing you control'),
            SwitchListTile(
              value: store.shareSummaryWithFamily,
              onChanged: (bool value) =>
                  store.setPrivacyOption(shareWithFamily: value),
              title: const Text('Send a summary to my family'),
              subtitle: const Text(
                'They see totals only - never the shops you visit.',
              ),
              secondary: const Icon(Icons.family_restroom_outlined),
            ),
            SwitchListTile(
              value: store.useDisplayNameWithHousemates,
              onChanged: (bool value) =>
                  store.setPrivacyOption(useDisplayName: value),
              title: const Text('Show my display name to housemates'),
              subtitle: const Text('Otherwise they only see their own share.'),
              secondary: const Icon(Icons.group_outlined),
            ),
            const SectionHeader(title: 'Your information'),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Download a copy of my information'),
              onTap: () => _showExport(context, store),
            ),
            ListTile(
              iconColor: Theme.of(context).colorScheme.error,
              textColor: Theme.of(context).colorScheme.error,
              leading: const Icon(Icons.delete_forever_outlined),
              title: const Text('Delete my information'),
              subtitle: const Text('Removes everything saved by MoneePocket.'),
              onTap: () => _confirmDeletion(context),
            ),
            ListTile(
              leading: const Icon(Icons.link_off_outlined),
              title: const Text('Disconnect my bank'),
              subtitle: Text(
                store.isBankLinked
                    ? '${store.linkedBankName} is linked. Your budgets stay.'
                    : 'No bank is linked right now.',
              ),
              enabled: store.isBankLinked,
              onTap: () {
                store.unlinkBankAccount();
                showBriefMessage(context, 'Your bank is disconnected.');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editName(BuildContext context, MoneePocketStore store) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        icon: Icons.badge_outlined,
        title: 'Display name',
        label: 'Name housemates see',
        initialText: store.displayName,
        confirmLabel: 'Save',
      ),
    );
    if (name != null) store.setDisplayName(name);
  }

  void _showExport(BuildContext context, MoneePocketStore store) {
    final String exported = store.exportAsText();
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Your information'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              exported,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: exported));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              if (context.mounted) showBriefMessage(context, 'Copied.');
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeletion(BuildContext context) async {
    final String? typed = await showDialog<String>(
      context: context,
      builder: (_) => const TextPromptDialog(
        icon: Icons.delete_outline,
        title: 'Delete everything?',
        message:
            'Your payments, budgets and shared bill are removed. This '
            'cannot be undone.',
        label: 'Type DELETE to confirm',
        mustEqual: 'DELETE',
        confirmLabel: 'Delete everything',
        cancelLabel: 'Keep my information',
      ),
    );
    if (typed == null || !context.mounted) return;
    MoneePocketScope.read(context).deleteEverything();
    showBriefMessage(context, 'Everything has been deleted.');
    context.go('/home');
  }
}

// ------------------------------------------------------------
// SCREEN - LINK A BANK (/home/link-bank)
//
// Informed consent, then store.linkBankAccount.
// ------------------------------------------------------------

class BankLinkScreen extends StatefulWidget {  // consent screen before linking a bank
  const BankLinkScreen({super.key});

  @override
  State<BankLinkScreen> createState() => _BankLinkScreenState();
}

class _BankLinkScreenState extends State<BankLinkScreen> {  // chosen bank and consent tick, before linking
  String? _selectedBank;
  bool _hasReadWhatIsShared = false;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Link a bank account')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            Text(
              'Linking gives MoneePocket a read-only view of your payments, '
              'so it can match your part-time pay. It never controls your '
              'money, and you can disconnect at any time.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('What MoneePocket will see', style: text.titleMedium),
                    const SizedBox(height: 12),
                    const _PlainFactRow(
                      icon: Icons.visibility_outlined,
                      text: 'The date, amount and shop name of each payment.',
                    ),
                    const _PlainFactRow(
                      icon: Icons.block_outlined,
                      text:
                          'Never your password. Never the power to move '
                          'money.',
                    ),
                    const _PlainFactRow(
                      icon: Icons.phone_iphone_outlined,
                      text: 'Payments are stored on this device.',
                    ),
                    const _PlainFactRow(
                      icon: Icons.link_off_outlined,
                      text:
                          'You can disconnect at any time and your '
                          'budgets stay.',
                    ),
                  ],
                ),
              ),
            ),
            CheckboxListTile(
              value: _hasReadWhatIsShared,
              onChanged: (bool? value) =>
                  setState(() => _hasReadWhatIsShared = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('I have read what will be shared'),
            ),
            const SectionHeader(title: 'Choose your bank'),
            RadioGroup<String>(
              groupValue: _selectedBank,
              onChanged: (String? value) =>
                  setState(() => _selectedBank = value),
              child: Column(
                children: <Widget>[
                  for (final String bank in MoneePocketServer.supportedBanks)
                    RadioListTile<String>(
                      value: bank,
                      title: Text(bank),
                      secondary: const Icon(Icons.account_balance_outlined),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _hasReadWhatIsShared && _selectedBank != null
                  ? _confirmConnection
                  : null,
              child: const Text('Connect securely'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmConnection() async {
    final String bankName = _selectedBank!;
    final bool confirmed = await confirmAction(
      context,
      icon: Icons.lock_outline,
      title: 'Connect to $bankName?',
      message: 'MoneePocket only receives a read-only view of your payments.',
      confirmLabel: 'Continue',
    );
    if (!confirmed || !mounted) return;
    MoneePocketScope.read(context).linkBankAccount(bankName);
    showBriefMessage(
      context,
      '$bankName connected. You can undo this in Privacy and data.',
    );
    context.pop();
  }
}

class _PlainFactRow extends StatelessWidget {  // one plain-language fact with an icon
  const _PlainFactRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// SCREEN - BUDGET (/budget)
//
// Weekly / Monthly / Yearly tabs. Each lists every category with its limit,
// spent and remaining; create, edit, clear or delete through the store.
// ------------------------------------------------------------

class BudgetSetupScreen extends StatefulWidget {  // Budget destination with three period tabs
  const BudgetSetupScreen({super.key});

  @override
  State<BudgetSetupScreen> createState() => _BudgetSetupScreenState();
}

class _BudgetSetupScreenState extends State<BudgetSetupScreen> {  // remembers the category just created
  String? _justCreated;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);

    return DefaultTabController(
      length: BudgetPeriod.values.length,
      initialIndex: BudgetPeriod.monthly.index,
      animationDuration: kTransitionDuration,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Budgets'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Add spending',
              icon: const Icon(Icons.add_card_outlined),
              onPressed: () => context.push('/add'),
            ),
          ],
          bottom: TabBar(
            tabs: <Widget>[
              for (final BudgetPeriod period in BudgetPeriod.values)
                Tab(text: period.label),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            for (final BudgetPeriod period in BudgetPeriod.values)
              _periodTab(store, period),
          ],
        ),
      ),
    );
  }

  Widget _periodTab(MoneePocketStore store, BudgetPeriod period) {
    return ReadableWidth(
      maxWidth: 1120,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          BudgetSummaryCard(
            period: period,
            action: FilledButton.icon(
              onPressed: () => _create(period),
              icon: const Icon(Icons.add),
              label: const Text('Create budget'),
            ),
          ),
          SectionHeader(
            title: 'Budget for each category',
            subtitle:
                'Tap a category to set or change its '
                '${period.label.toLowerCase()} budget.',
          ),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth >= 700
                  ? (constraints.maxWidth - 16) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: 16,
                runSpacing: 12,
                children: <Widget>[
                  for (final PeriodBudget budget in store.budgetsFor(period))
                    SizedBox(
                      width: width,
                      child: _ScrollIntoView(
                        active: budget.category.label == _justCreated,
                        child: _BudgetRow(
                          budget: budget,
                          highlighted: budget.category.label == _justCreated,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (period == BudgetPeriod.monthly) ...const <Widget>[
            SectionHeader(
              title: 'Does your plan fit?',
              subtitle: 'Planning only - this does not change your balance.',
            ),
            _AffordabilityCard(),
          ],
        ],
      ),
    );
  }

  Future<void> _create(BudgetPeriod period) async {
    final MoneePocketStore store = MoneePocketScope.read(context);
    final ({String name, double limitAud})? draft =
        await showModalBottomSheet<({String name, double limitAud})>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => _NewCategorySheet(
            period: period,
            takenLabels: <String>[
              for (final PeriodBudget budget in store.budgetsFor(period))
                if (budget.hasBudget) budget.category.label,
            ],
          ),
        );
    if (draft == null || !mounted) return;

    store.addCategory(draft.name, period, draft.limitAud);
    final String label = store.categoryBudgets
        .firstWhere(
          (CategoryBudget b) =>
              b.category.label.toLowerCase() == draft.name.toLowerCase(),
        )
        .category
        .label;
    showBriefMessage(
      context,
      '$label budget created: ${formatAud(draft.limitAud)} a ${period.noun}.',
    );
    setState(() => _justCreated = label);
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _justCreated = null);
    });
  }
}

class _ScrollIntoView extends StatefulWidget {  // scrolls a new category into view
  const _ScrollIntoView({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_ScrollIntoView> createState() => _ScrollIntoViewState();
}

class _ScrollIntoViewState extends State<_ScrollIntoView> {  // scrolls when the row becomes the new one
  @override
  void initState() {
    super.initState();
    if (widget.active) _reveal();
  }

  @override
  void didUpdateWidget(_ScrollIntoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reveal();
  }

  void _reveal() {
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.3,
        duration: kTransitionDuration,
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _BudgetRow extends StatelessWidget {  // category row: limit, spent, left; tap to edit
  const _BudgetRow({required this.budget, required this.highlighted});

  final PeriodBudget budget;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final String status = !budget.hasBudget
        ? 'Not set'
        : budget.isOverLimit
        ? 'Over ${formatAud(budget.overByAud)}'
        : 'Remaining ${formatAud(budget.remainingAud)}';

    return AnimatedContainer(
      duration: kTransitionDuration,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: highlighted
            ? colors.tertiaryContainer
            : colors.surfaceContainerLow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => _EditBudgetSheet(budget: budget),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    CategoryAvatar(category: budget.category),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        budget.category.label,
                        style: text.titleMedium,
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          formatAud(budget.limitAud),
                          style: text.titleMedium,
                        ),
                        Text(
                          status,
                          style: text.bodyMedium?.copyWith(
                            color: !budget.hasBudget
                                ? colors.onSurfaceVariant
                                : budget.isOverLimit
                                ? colors.error
                                : colors.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                BudgetBar(budget: budget),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Spent ${formatAud(budget.spentAud)}',
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AffordabilityCard extends StatelessWidget {  // compares monthly limits with expected income
  const _AffordabilityCard();

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final double monthly = store.limitFor(BudgetPeriod.monthly);
    final double overBy = monthly - store.expectedFundsAud;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            _TotalsRow(
              label: 'Your monthly budgets',
              value: formatAud(monthly),
            ),
            const SizedBox(height: 12),
            AmountInput(
              title: Text(
                'Expected income per month',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              valueAud: store.expectedFundsAud,
              onChanged: store.setExpectedFunds,
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Payday',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                DropdownMenu<int>(
                  key: ValueKey<int>(store.paydayWeekday),
                  initialSelection: store.paydayWeekday,
                  width: 170,
                  onSelected: (int? weekday) {
                    if (weekday != null) store.setPayday(weekday);
                  },
                  dropdownMenuEntries: <DropdownMenuEntry<int>>[
                    for (
                      int day = DateTime.monday;
                      day <= DateTime.sunday;
                      day++
                    )
                      DropdownMenuEntry<int>(
                        value: day,
                        label: formatWeekday(day),
                      ),
                  ],
                ),
              ],
            ),
            const Divider(height: 32),
            StatusNote(
              isProblem: !store.limitsAreAffordable,
              message: store.limitsAreAffordable
                  ? 'Your plan fits. ${formatAud(-overBy)} of your expected '
                        'income is not budgeted.'
                  : 'Your budgets are ${formatAud(overBy)} more than your '
                        'expected income. Lower a budget to fit it.',
            ),
          ],
        ),
      ),
    );
  }
}

class _EditBudgetSheet extends StatefulWidget {  // edit sheet: slider + text field for a limit
  const _EditBudgetSheet({required this.budget});

  final PeriodBudget budget;

  @override
  State<_EditBudgetSheet> createState() => _EditBudgetSheetState();
}

class _EditBudgetSheetState extends State<_EditBudgetSheet> {  // local input until Save calls the store
  late double _limit = widget.budget.limitAud;

  SpendingCategory get _category => widget.budget.category;

  BudgetPeriod get _period => widget.budget.period;

  void _save() {
    MoneePocketScope.read(context).updateBudget(_category, _period, _limit);
    showBriefMessage(context, '${_category.label} budget updated.');
    Navigator.of(context).pop();
  }

  void _clear() {
    final MoneePocketStore store = MoneePocketScope.read(context);
    final double oldLimit = widget.budget.limitAud;
    store.updateBudget(_category, _period, 0);
    showBriefMessage(
      context,
      '${_category.label} budget cleared.',
      actionLabel: 'Undo',
      onAction: () => store.updateBudget(_category, _period, oldLimit),
    );
    Navigator.of(context).pop();
  }

  Future<void> _deleteCategory() async {
    final MoneePocketStore store = MoneePocketScope.read(context);
    final int payments = store.expenses
        .where((Expense e) => e.category == _category)
        .length;
    final bool confirmed = await confirmAction(
      context,
      icon: Icons.delete_outline,
      title: 'Delete ${_category.label}?',
      message: payments == 0
          ? 'This category is removed from Budget, Add spending and '
                'Summary.'
          : 'This category and its $payments payments are removed '
                'everywhere. The payments\' amounts return to your account '
                'balance.',
      confirmLabel: 'Delete category',
    );
    if (!confirmed || !mounted) return;
    final DeletedCategory deleted = store.deleteCategory(_category);
    showBriefMessage(
      context,
      '${_category.label} deleted.',
      actionLabel: 'Undo',
      onAction: () => store.restoreCategory(deleted),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AmountInput(
              leading: CategoryAvatar(category: _category),
              title: Text(_category.label, style: text.titleLarge),
              valueAud: _limit,
              sliderMax: _period.sliderMaxAud,
              onChanged: (double value) =>
                  setState(() => _limit = value.roundToDouble()),
            ),
            Text(
              '${_period.label} budget · spent this ${_period.noun} '
              '${formatAud(widget.budget.spentAud)}',
              style: text.bodySmall,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                TextButton(
                  onPressed: widget.budget.hasBudget ? _clear : null,
                  child: const Text('Clear budget'),
                ),
                if (_category.isCustom)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: colors.error),
                    onPressed: _deleteCategory,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete category'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NewCategorySheet extends StatefulWidget {  // sheet to create a category: name and limit
  const _NewCategorySheet({required this.period, required this.takenLabels});

  final BudgetPeriod period;
  final List<String> takenLabels;

  @override
  State<_NewCategorySheet> createState() => _NewCategorySheetState();
}

class _NewCategorySheetState extends State<_NewCategorySheet> {  // validates the name and limit before saving
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  String? _nameError;
  String? _amountError;

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _nameController.text.trim();
    final double? limit = double.tryParse(_amountController.text.trim());
    final bool taken = widget.takenLabels.any(
      (String label) => label.toLowerCase() == name.toLowerCase(),
    );
    setState(() {
      _nameError = name.isEmpty
          ? 'Give the category a name.'
          : taken
          ? '"$name" already has a ${widget.period.label.toLowerCase()} '
                'budget. Tap it in the list to change it.'
          : null;
      _amountError = limit == null || limit <= 0
          ? 'Enter an amount, for example 200'
          : null;
    });
    if (_nameError == null && _amountError == null) {
      Navigator.of(context).pop((name: name, limitAud: limit!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Create ${widget.period.label.toLowerCase()} budget',
              style: text.titleLarge,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'What is it for?',
                hintText: 'For example: Sport',
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText:
                    'How much can you spend on it each ${widget.period.noun}?',
                prefixText: '\$ ',
                border: const OutlineInputBorder(),
                errorText: _amountError,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
                child: const Text('Create budget'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsRow extends StatelessWidget {  // label and value on one line
  const _TotalsRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Expanded(child: Text(label, style: text.bodyMedium)),
        Text(value, style: text.titleMedium),
      ],
    );
  }
}

// ------------------------------------------------------------
// SCREEN - SPLIT A BILL (/split)
//
// Split a household bill equally or by custom amounts; swipe a housemate
// away to remove them. Sending stores the request in the store.
// ------------------------------------------------------------

class SharedBillSplitScreen extends StatefulWidget {  // Split destination: divide a household bill
  const SharedBillSplitScreen({super.key});

  @override
  State<SharedBillSplitScreen> createState() => _SharedBillSplitScreenState();
}

class _SharedBillSplitScreenState extends State<SharedBillSplitScreen>  // owns the tabs and the bill form fields
    with SingleTickerProviderStateMixin {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _totalController = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _totalFocus = FocusNode();
  late final TabController _tabController;
  late final MoneePocketStore _store;
  String? _sendError;

  @override
  void initState() {
    super.initState();
    _store = MoneePocketScope.read(context);
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: _store.splitMethod == SplitMethod.equal ? 0 : 1,
      animationDuration: kTransitionDuration,
    )..addListener(_onTabChanged);
    _copyStoreIntoFields();
    _store.addListener(_copyStoreIntoFields);
  }

  void _copyStoreIntoFields() {
    if (!_titleFocus.hasFocus &&
        _titleController.text != _store.sharedBillDescription) {
      _titleController.text = _store.sharedBillDescription;
    }
    final String total = _store.sharedBillTotalAud == 0
        ? ''
        : _store.sharedBillTotalAud.toStringAsFixed(2);
    if (!_totalFocus.hasFocus && _totalController.text != total) {
      _totalController.text = total;
    }
    final int tab = _store.splitMethod == SplitMethod.equal ? 0 : 1;
    if (_tabController.index != tab && !_tabController.indexIsChanging) {
      _tabController.index = tab;
    }
  }

  void _onTabChanged() {
    final SplitMethod chosen = _tabController.index == 0
        ? SplitMethod.equal
        : SplitMethod.custom;
    if (_store.splitMethod != chosen) _store.setSplitMethod(chosen);
  }

  @override
  void dispose() {
    _store.removeListener(_copyStoreIntoFields);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _titleController.dispose();
    _totalController.dispose();
    _titleFocus.dispose();
    _totalFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    final Widget titleField = TextFormField(
      controller: _titleController,
      focusNode: _titleFocus,
      textCapitalization: TextCapitalization.sentences,
      onChanged: store.setBillDescription,
      validator: (String? value) => (value ?? '').trim().isEmpty
          ? 'Give this bill a title so everyone knows what it is.'
          : null,
      decoration: const InputDecoration(
        labelText: 'Bill title',
        hintText: 'For example: Electricity',
        border: OutlineInputBorder(),
      ),
    );
    final Widget totalField = TextFormField(
      controller: _totalController,
      focusNode: _totalFocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (String value) {
        final double? parsed = double.tryParse(value.trim());
        if (parsed != null && parsed > 0) store.setBillTotal(parsed);
      },
      validator: (String? value) {
        final double? parsed = double.tryParse((value ?? '').trim());
        if (parsed == null) return 'Use numbers only, for example 189.20.';
        if (parsed <= 0) return 'Enter a total greater than zero.';
        return null;
      },
      decoration: const InputDecoration(
        labelText: 'Total on the bill',
        prefixText: '\$ ',
        border: OutlineInputBorder(),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Split a bill'),
        actions: <Widget>[
          if (store.sharesWereSent)
            IconButton(
              tooltip: 'See replies',
              icon: const Icon(Icons.forum_outlined),
              onPressed: () => context.push('/split/status'),
            ),
          IconButton(
            tooltip: 'Start a new bill',
            icon: const Icon(Icons.restart_alt_outlined),
            onPressed: _startNewBill,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const <Widget>[
            Tab(text: 'Split equally', icon: Icon(Icons.balance_outlined)),
            Tab(text: 'Custom shares', icon: Icon(Icons.tune_outlined)),
          ],
        ),
      ),
      body: ReadableWidth(
        maxWidth: 980,
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            children: <Widget>[
              Expanded(
                child: NestedScrollView(
                  headerSliverBuilder: (BuildContext context, bool scrolled) =>
                      <Widget>[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: Column(
                              children: <Widget>[
                                LayoutBuilder(
                                  builder:
                                      (
                                        BuildContext context,
                                        BoxConstraints constraints,
                                      ) => constraints.maxWidth < 700
                                      ? Column(
                                          children: <Widget>[
                                            titleField,
                                            const SizedBox(height: 12),
                                            totalField,
                                          ],
                                        )
                                      : Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Expanded(child: titleField),
                                            const SizedBox(width: 16),
                                            Expanded(child: totalField),
                                          ],
                                        ),
                                ),
                                ReceiptAttachmentTile(
                                  receiptName: store.sharedBillReceiptName,
                                  onAttach: _attachReceipt,
                                  onRemove: () => store.setBillReceipt(null),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                  body: TabBarView(
                    controller: _tabController,
                    children: <Widget>[
                      const _EqualSplitView(),
                      _CustomSplitView(
                        key: ValueKey<int>(store.sharesRevision),
                      ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: <Widget>[
                      Text(
                        store.useDisplayNameWithHousemates
                            ? 'Housemates see the bill total, their own share '
                                  'and your display name '
                                  '"${store.housemateShares.first.firstName}".'
                            : 'Housemates see the bill total and their own '
                                  'share.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _send,
                          icon: const Icon(Icons.send_outlined),
                          label: const Text('Send shares for agreement'),
                        ),
                      ),
                      if (_sendError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _sendError!,
                            style: text.bodySmall?.copyWith(
                              color: colors.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _send() {
    final bool formValid =
        (_formKey.currentState?.validate() ?? false) &&
        _store.sharedBillDescription.trim().isNotEmpty &&
        _store.sharedBillTotalAud > 0;
    final double allocated = _store.housemateShares.fold<double>(
      0,
      (double sum, HousemateShare s) => sum + s.amountAud,
    );
    final bool balances = (allocated - _store.sharedBillTotalAud).abs() < 0.01;
    final String? error = !formValid
        ? 'Check the title and total above.'
        : _store.housemateShares.length < 2
        ? 'Add at least one housemate before sending.'
        : !balances
        ? 'The shares must add up to the bill total before sending.'
        : null;
    setState(() => _sendError = error);
    if (error != null) return;
    _store.sendSharesForAgreement();
    showBriefMessage(
      context,
      'Shares sent to ${_store.housemateShares.length - 1} housemates.',
    );
    context.push('/split/status');
  }

  Future<void> _attachReceipt() async {
    final String? name = await chooseReceipt(context, 'bill');
    if (name != null) _store.setBillReceipt(name);
  }

  Future<void> _startNewBill() async {
    final bool confirmed = await confirmAction(
      context,
      icon: Icons.restart_alt_outlined,
      title: 'Start a new bill?',
      message:
          'This clears the title, total, housemates and receipt. Your '
          'recorded spending stays.',
      confirmLabel: 'Start new bill',
      cancelLabel: 'Keep editing',
    );
    if (!confirmed || !mounted) return;
    _store.resetBill();
    setState(() => _sendError = null);
  }
}

class _EqualSplitView extends StatelessWidget {  // equal split: housemates and their shares
  const _EqualSplitView();

  Future<void> _addHousemate(BuildContext context) async {
    final MoneePocketStore store = MoneePocketScope.read(context);
    final String? name = await showDialog<String>(
      context: context,
      builder: (_) => const TextPromptDialog(
        icon: Icons.person_add_alt_1_outlined,
        title: 'Add a housemate',
        label: 'First name',
        hint: 'For example: Priya',
        confirmLabel: 'Add',
      ),
    );
    if (name != null && name.isNotEmpty) store.addHousemate(name);
  }

  void _remove(BuildContext context, int index) {
    final MoneePocketStore store = MoneePocketScope.read(context);
    final HousemateShare removed = store.housemateShares[index];
    store.removeHousemate(index);
    showBriefMessage(
      context,
      '${removed.firstName} removed from this bill',
      actionLabel: 'Undo',
      onAction: () => store.insertHousemate(index, removed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int people = store.housemateShares.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: <Widget>[
                Text(
                  'Bill total',
                  style: text.titleSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatAud(store.sharedBillTotalAud),
                  style: text.displaySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  'Each of $people pays about '
                  '${formatAud(store.sharedBillTotalAud / people)}',
                ),
              ],
            ),
          ),
        ),
        const SectionHeader(title: 'Who is sharing this bill'),
        for (int index = 0; index < people; index++)
          _dismissibleRow(context, store, index),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _addHousemate(context),
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Add a housemate'),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _dismissibleRow(
    BuildContext context,
    MoneePocketStore store,
    int index,
  ) {
    final HousemateShare share = store.housemateShares[index];
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget row = ListTile(
      leading: CircleAvatar(child: Text(share.firstName.characters.first)),
      title: Text(share.firstName),
      subtitle: Text(index == 0 ? 'You' : 'Housemate - swipe to remove'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            formatAud(share.amountAud),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (index != 0)
            IconButton(
              tooltip: 'Remove ${share.firstName}',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => _remove(context, index),
            ),
        ],
      ),
    );
    if (index == 0) return row;
    return Dismissible(
      key: ObjectKey(share),
      direction: DismissDirection.endToStart,
      background: _SwipeBackground(
        color: colors.errorContainer,
        foreground: colors.onErrorContainer,
        icon: Icons.person_remove_outlined,
        label: 'Remove',
        alignment: Alignment.centerRight,
      ),
      onDismissed: (_) => _remove(context, index),
      child: row,
    );
  }
}

class _CustomSplitView extends StatelessWidget {  // custom split: slider and text field per person
  const _CustomSplitView({super.key});

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final double allocated = store.housemateShares.fold<double>(
      0,
      (double sum, HousemateShare s) => sum + s.amountAud,
    );
    final double difference = store.sharedBillTotalAud - allocated;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      children: <Widget>[
        for (int index = 0; index < store.housemateShares.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: AmountInput(
              leading: CircleAvatar(
                child: Text(
                  store.housemateShares[index].firstName.characters.first,
                ),
              ),
              title: Text(store.housemateShares[index].firstName),
              valueAud: store.housemateShares[index].amountAud,
              sliderMax: store.sharedBillTotalAud,
              decimals: 2,
              onChanged: (double value) => store.setCustomShare(index, value),
            ),
          ),
        StatusNote(
          isProblem: difference.abs() >= 0.01,
          message: difference.abs() < 0.01
              ? 'The shares add up to the bill.'
              : difference > 0
              ? '${formatAud(difference)} of the bill is not shared yet.'
              : 'The shares are ${formatAud(-difference)} more than the '
                    'bill.',
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

// ------------------------------------------------------------
// SCREEN - SPLIT STATUS (/split/status)
//
// Housemates' replies (pull down to refresh); recording saves only the
// user's own share as a payment.
// ------------------------------------------------------------

class SplitStatusScreen extends StatelessWidget {  // replies from housemates; pull down to refresh
  const SplitStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool someoneQueried = store.housemateShares.any(
      (HousemateShare share) => share.response == ShareResponse.queried,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          store.sharedBillDescription.isEmpty
              ? 'Split status'
              : store.sharedBillDescription,
        ),
      ),
      body: ReadableWidth(
        child: RefreshIndicator(
          onRefresh: store.refreshReplies,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: <Widget>[
                      for (final HousemateShare share in store.housemateShares)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: <Widget>[
                              Expanded(child: Text(share.firstName)),
                              Text(formatAud(share.amountAud)),
                            ],
                          ),
                        ),
                      const Divider(height: 20),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text('Total', style: text.titleMedium),
                          ),
                          Text(
                            formatAud(store.sharedBillTotalAud),
                            style: text.titleLarge,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              SectionHeader(
                title: 'What everyone said',
                trailing: Text('Pull down to refresh', style: text.labelSmall),
              ),
              for (final HousemateShare share in store.housemateShares)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(share.firstName.characters.first),
                  ),
                  title: Text(share.firstName),
                  subtitle: Text(formatAud(share.amountAud)),
                  trailing: Chip(
                    avatar: Icon(share.response.icon, size: 18),
                    label: Text(share.response.label),
                  ),
                ),
              const SizedBox(height: 16),
              if (!store.sharesWereSent)
                const StatusNote(
                  isProblem: true,
                  message:
                      'These shares have not been sent. Go back to '
                      'Split and send them.',
                )
              else if (someoneQueried)
                Card.outlined(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Someone asked to change their share',
                          style: text.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Nothing is recorded until everyone '
                          'agrees. Change the amounts and send them again.',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: () => context.pop(),
                          child: const Text('Adjust the shares'),
                        ),
                      ],
                    ),
                  ),
                )
              else if (store.allSharesAgreed)
                FilledButton(
                  onPressed: () => _record(context),
                  child: const Text('Record what everyone owes'),
                )
              else
                const StatusNote(
                  message:
                      'Waiting for replies. Pull down to check '
                      'again.',
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _record(BuildContext context) async {
    final MoneePocketStore store = MoneePocketScope.read(context);
    final bool confirmed = await confirmAction(
      context,
      icon: Icons.receipt_long_outlined,
      title: 'Record this split?',
      message: 'Your share is added to ${store.sharedBillCategory.label}.',
      confirmLabel: 'Record',
    );
    if (!confirmed || !context.mounted) return;
    final Expense expense = store.recordSplit();
    showBriefMessage(
      context,
      'Split recorded. ${formatAud(expense.amountAud)} is your share.',
    );
    context.pop();
  }
}

// ------------------------------------------------------------
// SCREEN - SPENDING SUMMARY (/summary, /summary/category/:index)
//
// This week / month / year: Budget - Spent = Remaining, donut chart and
// categories sorted by spending; list-detail on wide windows.
// ------------------------------------------------------------

class SpendingSummaryScreen extends StatefulWidget {  // Summary destination with search and three tabs
  const SpendingSummaryScreen({super.key});

  @override
  State<SpendingSummaryScreen> createState() => _SpendingSummaryScreenState();
}

class _SpendingSummaryScreenState extends State<SpendingSummaryScreen> {  // list-detail on windows 840 dp or wider
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final int selected = _selectedIndex < store.categoryBudgets.length
        ? _selectedIndex
        : 0;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool twoPane = constraints.maxWidth >= 840;
        return DefaultTabController(
          length: BudgetPeriod.values.length,
          initialIndex: BudgetPeriod.monthly.index,
          animationDuration: kTransitionDuration,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Summary'),
              bottom: TabBar(
                tabs: <Widget>[
                  for (final BudgetPeriod range in BudgetPeriod.values)
                    Tab(text: 'This ${range.noun}'),
                ],
              ),
            ),
            body: Column(
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: _TransactionSearchBar(),
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      for (final BudgetPeriod range in BudgetPeriod.values)
                        _SummaryPane(
                          range: range,
                          twoPane: twoPane,
                          selectedIndex: selected,
                          onOpen: (int index) {
                            if (twoPane) {
                              setState(() => _selectedIndex = index);
                            } else {
                              context.push(
                                '/summary/category/$index?range=${range.name}',
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TransactionSearchBar extends StatelessWidget {  // M3 search bar over all payments
  const _TransactionSearchBar();

  @override
  Widget build(BuildContext context) {
    return SearchAnchor.bar(
      barHintText: 'Search your spending',
      suggestionsBuilder:
          (BuildContext viewContext, SearchController controller) {
            final String query = controller.text.trim().toLowerCase();
            final List<Expense> matches = MoneePocketScope.read(context)
                .expenses
                .where(
                  (Expense e) =>
                      e.description.toLowerCase().contains(query) ||
                      e.category.label.toLowerCase().contains(query),
                )
                .toList();
            return <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  matches.isEmpty
                      ? 'No payments match.'
                      : 'Results (${matches.length})',
                  style: Theme.of(viewContext).textTheme.titleSmall,
                ),
              ),
              for (final Expense expense in matches)
                ListTile(
                  leading: CategoryAvatar(
                    category: expense.category,
                    radius: 18,
                  ),
                  title: Text(expense.description),
                  subtitle: Text(
                    '${expense.category.label} · ${expense.whenLabel}',
                  ),
                  trailing: Text(formatAud(expense.amountAud)),
                  onTap: () {
                    controller.closeView(expense.description);
                    context.push('/expense/${expense.id}');
                  },
                ),
            ];
          },
    );
  }
}

class _SummaryPane extends StatelessWidget {  // one period: calculator, donut and categories
  const _SummaryPane({
    required this.range,
    required this.twoPane,
    required this.selectedIndex,
    required this.onOpen,
  });

  final BudgetPeriod range;
  final bool twoPane;
  final int selectedIndex;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final DateTimeRange dates = range.currentRange(DateTime.now());
    final double spent = store.spentBetween(null, dates);
    final List<int> order =
        <int>[for (int i = 0; i < store.categoryBudgets.length; i++) i]..sort(
          (int a, int b) => store
              .spentBetween(store.categoryBudgets[b].category, dates)
              .compareTo(
                store.spentBetween(store.categoryBudgets[a].category, dates),
              ),
        );
    final Widget list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: <Widget>[
        _CalculatorCard(
          budgetAud: store.limitFor(range) > 0 ? store.limitFor(range) : null,
          spentAud: spent,
          dates: dates,
          range: range,
        ),
        const SizedBox(height: 16),
        Center(
          child: DonutChart(
            slices: <ChartSlice>[
              for (final int i in order)
                ChartSlice(
                  store.categoryBudgets[i].category,
                  store.spentBetween(store.categoryBudgets[i].category, dates),
                ),
            ],
            centre: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Spent', style: text.bodySmall),
                Text(formatAud(spent), style: text.titleMedium),
              ],
            ),
          ),
        ),
        SectionHeader(
          title: 'All spending this ${range.noun}',
          subtitle: 'Every category, highest first. Tap for the payments.',
        ),
        Card(
          child: Column(
            children: <Widget>[
              for (final int i in order)
                _CategoryShareTile(
                  category: store.categoryBudgets[i].category,
                  spentAud: store.spentBetween(
                    store.categoryBudgets[i].category,
                    dates,
                  ),
                  totalAud: spent,
                  isSelected: twoPane && i == selectedIndex,
                  onTap: () => onOpen(i),
                ),
            ],
          ),
        ),
      ],
    );

    if (!twoPane) return ReadableWidth(child: list);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(flex: 2, child: list),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          flex: 3,
          child: CategoryDetailPane(
            category: store.categoryBudgets[selectedIndex].category,
            range: range,
          ),
        ),
      ],
    );
  }
}

class _CalculatorCard extends StatelessWidget {  // Budget - Spent = Remaining
  const _CalculatorCard({
    required this.budgetAud,
    required this.spentAud,
    required this.dates,
    required this.range,
  });

  final double? budgetAud;
  final double spentAud;
  final DateTimeRange dates;
  final BudgetPeriod range;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double? budget = budgetAud;
    final double remaining = (budget ?? 0) - spentAud;

    Widget line(String label, String value, {TextStyle? style}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: text.bodyLarge)),
          Text(value, style: style ?? text.titleMedium),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'This ${range.noun}',
              style: text.labelLarge?.copyWith(color: colors.primary),
            ),
            Text(
              budget == null
                  ? '${formatRange(dates)} · no ${range.label.toLowerCase()} budgets set'
                  : '${formatRange(dates)} · all categories',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            if (budget == null)
              line(
                'Spent',
                formatAud(spentAud),
                style: text.headlineSmall?.copyWith(color: colors.tertiary),
              )
            else ...<Widget>[
              line('Budget', formatAud(budget)),
              line(
                'Spent',
                '- ${formatAud(spentAud)}',
                style: text.titleMedium?.copyWith(color: colors.tertiary),
              ),
              const Divider(height: 20),
              line(
                remaining < 0 ? 'Over budget' : 'Remaining',
                formatAud(remaining.abs()),
                style: text.headlineSmall?.copyWith(
                  color: remaining < 0 ? colors.error : colors.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryShareTile extends StatelessWidget {  // category row sorted by spending; tap for payments
  const _CategoryShareTile({
    required this.category,
    required this.spentAud,
    required this.totalAud,
    required this.isSelected,
    required this.onTap,
  });

  final SpendingCategory category;
  final double spentAud;
  final double totalAud;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double share = totalAud <= 0 ? 0 : spentAud / totalAud;
    return ListTile(
      selected: isSelected,
      selectedTileColor: colors.secondaryContainer,
      onTap: onTap,
      leading: CategoryAvatar(category: category),
      title: Text(category.label, style: text.titleMedium),
      subtitle: Text('${(share * 100).round()}% of your spending'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            formatAud(spentAud),
            style: text.titleMedium?.copyWith(
              color: spentAud > 0 ? colors.tertiary : null,
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

class CategoryDetailScreen extends StatelessWidget {  // full page of one category on compact windows
  const CategoryDetailScreen({
    super.key,
    required this.index,
    required this.range,
  });

  final int index;
  final BudgetPeriod range;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    if (index >= store.categoryBudgets.length) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This category no longer exists.')),
      );
    }
    final SpendingCategory category = store.categoryBudgets[index].category;
    return Scaffold(
      appBar: AppBar(title: Text(category.label)),
      body: ReadableWidth(
        child: CategoryDetailPane(category: category, range: range),
      ),
    );
  }
}

class CategoryDetailPane extends StatelessWidget {  // one category's payments; side pane when expanded
  const CategoryDetailPane({
    super.key,
    required this.category,
    required this.range,
  });

  final SpendingCategory category;
  final BudgetPeriod range;

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final PeriodBudget budget = store.budgetFor(category, range);
    final List<Expense> payments = store
        .expensesBetween(category, range.currentRange(DateTime.now()))
        .toList();
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: <Widget>[
        Row(
          children: <Widget>[
            CategoryAvatar(category: category, radius: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(category.label, style: text.headlineSmall)),
          ],
        ),
        const SizedBox(height: 16),
        if (!budget.hasBudget)
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(
                'No ${range.label.toLowerCase()} budget for this category',
              ),
              subtitle: const Text(
                'Create one on the Budget screen to set a limit.',
              ),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'This ${range.noun}\'s budget',
                    style: text.labelLarge?.copyWith(color: colors.primary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatAud(budget.spentAud)} of '
                    '${formatAud(budget.limitAud)}',
                    style: text.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  BudgetBar(budget: budget, thickness: 10),
                  const SizedBox(height: 8),
                  Text(
                    budget.isOverLimit
                        ? 'Over by ${formatAud(budget.overByAud)}'
                        : 'Remaining ${formatAud(budget.remainingAud)}',
                    style: text.titleSmall?.copyWith(
                      color: budget.isOverLimit ? colors.error : colors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        SectionHeader(
          title: 'Payments',
          subtitle: 'This ${range.noun} · ${payments.length} payments',
        ),
        if (payments.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing recorded here in this range.'),
          )
        else
          Card(
            child: Column(
              children: <Widget>[
                for (final Expense expense in payments)
                  SwipeableExpenseTile(expense: expense),
              ],
            ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------
// SCREEN - ADD SPENDING (/add)
//
// Form for a new payment (store.recordExpense) or, with an id, an edit
// (store.updateExpense). Input is local state until Save. Warns when a
// budget is exceeded.
// ------------------------------------------------------------

class AddExpenseScreen extends StatefulWidget {  // form to add a payment, or edit one by id
  const AddExpenseScreen({super.key, this.editId});

  final String? editId;

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {  // local form state until Save calls the store
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  SpendingCategory? _category;
  String? _receiptName;
  DateTime _date = dateOnly(DateTime.now());
  bool _showMoreDetails = false;

  Expense? _editing;

  double? get _amount {
    final double? parsed = double.tryParse(_amountController.text.trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }

  bool get _canSave => _amount != null && _category != null;

  @override
  void initState() {
    super.initState();
    final String? editId = widget.editId;
    final Expense? editing = editId == null
        ? null
        : MoneePocketScope.read(context).expenseById(editId);
    if (editing != null) {
      _editing = editing;
      _amountController.text = editing.amountAud.toStringAsFixed(2);
      if (editing.description != editing.category.label) {
        _noteController.text = editing.description;
      }
      _category = editing.category;
      _receiptName = editing.receiptName;
      _date = dateOnly(editing.date);
      _showMoreDetails = true;
    }
    _amountController.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _amountController
      ..removeListener(_refresh)
      ..dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isToday = daysBetween(_date, DateTime.now()) == 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing == null ? 'Add spending' : 'Edit payment'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => context.pop(),
        ),
      ),
      body: ReadableWidth(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: <Widget>[
              TextFormField(
                controller: _amountController,
                autofocus: _editing == null,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: text.headlineMedium,
                decoration: const InputDecoration(
                  labelText: 'How much did you spend? *',
                  prefixText: '\$ ',
                  border: OutlineInputBorder(),
                ),
                validator: _validateAmount,
              ),
              const SizedBox(height: 20),
              Text.rich(
                TextSpan(
                  text: 'What was it for? ',
                  style: text.titleMedium,
                  children: <InlineSpan>[
                    TextSpan(
                      text: '*',
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final CategoryBudget budget in store.categoryBudgets)
                    ChoiceChip(
                      selected: _category == budget.category,
                      onSelected: (_) =>
                          setState(() => _category = budget.category),
                      avatar: Icon(budget.category.icon, size: 18),
                      label: Text(budget.category.label),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _noteController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  hintText: 'For example: lunch with Mai',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _showMoreDetails = !_showMoreDetails),
                  icon: AnimatedRotation(
                    turns: _showMoreDetails ? 0.5 : 0,
                    duration: kTransitionDuration,
                    child: const Icon(Icons.expand_more),
                  ),
                  label: const Text('More details (optional)'),
                ),
              ),
              AnimatedSize(
                duration: kTransitionDuration,
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: _showMoreDetails
                    ? Card.outlined(
                        child: Column(
                          children: <Widget>[
                            ListTile(
                              leading: const Icon(Icons.event_outlined),
                              title: const Text('When'),
                              subtitle: Text(
                                isToday
                                    ? 'Today'
                                    : '${formatWeekday(_date.weekday)} '
                                          '${formatDayMonth(_date)}',
                              ),
                              trailing: const Icon(
                                Icons.edit_calendar_outlined,
                              ),
                              onTap: _pickDate,
                            ),
                            ReceiptAttachmentTile(
                              receiptName: _receiptName,
                              onAttach: _attachReceipt,
                              onRemove: () =>
                                  setState(() => _receiptName = null),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _canSave ? _save : null,
                child: Text(
                  _editing == null ? 'Save spending' : 'Save changes',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _canSave
                    ? 'Ready to save.'
                    : 'Fields marked * are needed: an amount and what it '
                          'was for.',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _validateAmount(String? value) {
    final String raw = (value ?? '').trim();
    if (raw.isEmpty) return 'Enter how much you spent.';
    final double? parsed = double.tryParse(raw);
    if (parsed == null) return 'Use numbers only, for example 12.50';
    if (parsed <= 0) return 'The amount needs to be more than zero.';
    return null;
  }

  Future<void> _pickDate() async {
    final DateTime today = dateOnly(DateTime.now());
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today,
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _attachReceipt() async {
    final String? name = await chooseReceipt(context, 'receipt');
    if (name != null && mounted) setState(() => _receiptName = name);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false) || !_canSave) return;
    final MoneePocketStore store = MoneePocketScope.read(context);
    final DateTime now = DateTime.now();
    final String note = _noteController.text.trim();
    final Expense? editing = _editing;
    if (editing != null) {
      store.updateExpense(
        Expense(
          id: editing.id,
          description: note.isEmpty ? _category!.label : note,
          amountAud: _amount!,
          category: _category!,
          date: DateTime(
            _date.year,
            _date.month,
            _date.day,
            editing.date.hour,
            editing.date.minute,
            editing.date.second,
          ),
          receiptName: _receiptName,
          isShared: editing.isShared,
        ),
      );
      showBriefMessage(context, 'Payment updated.');
      context.pop();
      return;
    }
    final Expense expense = Expense(
      id: store.newId(),
      description: note.isEmpty ? _category!.label : note,
      amountAud: _amount!,
      category: _category!,
      date: DateTime(
        _date.year,
        _date.month,
        _date.day,
        now.hour,
        now.minute,
        now.second,
      ),
      receiptName: _receiptName,
    );
    store.recordExpense(expense);

    final PeriodBudget budget = store.budgetToReport(expense.category);
    if (budget.isOverLimit) {
      final bool adjust =
          await showDialog<bool>(
            context: context,
            builder: (_) => OverspendingDialog(budget: budget),
          ) ??
          false;
      if (!mounted) return;
      if (adjust) {
        context.go('/budget');
        return;
      }
    }
    if (mounted) context.pushReplacement('/saved/${expense.id}');
  }
}

class OverspendingDialog extends StatelessWidget {  // over-limit dialog: Keep spending or Adjust budget
  const OverspendingDialog({super.key, required this.budget});

  final PeriodBudget budget;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      semanticLabel: 'Over your ${budget.period.label.toLowerCase()} budget',
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Chip(
            avatar: Icon(Icons.error_outline, color: colors.onErrorContainer),
            label: Text(
              'Over your ${budget.period.label.toLowerCase()} budget',
            ),
            backgroundColor: colors.errorContainer,
            labelStyle: TextStyle(color: colors.onErrorContainer),
            side: BorderSide.none,
          ),
          const SizedBox(height: 16),
          Text(
            formatAud(budget.overByAud),
            style: text.displaySmall?.copyWith(color: colors.error),
          ),
          Text(
            'over your ${budget.category.label} limit',
            style: text.titleMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          BudgetBar(budget: budget),
          const SizedBox(height: 8),
          Text(
            'Limit ${formatAud(budget.limitAud)} · '
            'Spent ${formatAud(budget.spentAud)}',
            style: text.bodySmall,
          ),
          const SizedBox(height: 16),
          const Text(
            'Your spending is saved. Nothing is blocked - you can '
            'raise the limit or leave it as it is.',
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep spending'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Adjust budget'),
        ),
      ],
    );
  }
}

class ReceiptAttachmentTile extends StatelessWidget {  // optional receipt row on the form
  const ReceiptAttachmentTile({
    super.key,
    required this.receiptName,
    required this.onAttach,
    required this.onRemove,
  });

  final String? receiptName;
  final VoidCallback onAttach;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final bool attached = receiptName != null;
    return ListTile(
      leading: Icon(attached ? Icons.receipt_long : Icons.add_a_photo_outlined),
      title: Text(
        attached
            ? 'Receipt attached'
            : 'Add a photo of your receipt (optional)',
      ),
      subtitle: Text(
        attached
            ? '$receiptName · stored on this device'
            : 'Useful if you may need to prove a shared bill later.',
      ),
      trailing: attached
          ? TextButton(onPressed: onRemove, child: const Text('Remove'))
          : const Icon(Icons.chevron_right),
      onTap: attached ? null : onAttach,
    );
  }
}

// ------------------------------------------------------------
// SCREEN - SAVED CONFIRMATION (/saved/:id)
//
// Confirms the payment and shows what remains in its budget.
// ------------------------------------------------------------

class ExpenseSavedScreen extends StatelessWidget {  // confirmation with what is left in the budget
  const ExpenseSavedScreen({super.key, required this.expenseId});

  final String expenseId;

  void _close(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final MoneePocketStore store = MoneePocketScope.of(context);
    final Expense? expense = store.expenseById(expenseId);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    if (expense == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Saved')),
        body: Center(
          child: FilledButton(
            onPressed: () => _close(context),
            child: const Text('This payment was removed - go back'),
          ),
        ),
      );
    }
    final PeriodBudget budget = store.budgetToReport(expense.category);
    final String period = budget.period.label.toLowerCase();
    final String effect = !budget.hasBudget
        ? '${budget.category.label} has no budget, so no limit is affected.'
        : budget.isOverLimit
        ? '${budget.category.label} is now ${formatAud(budget.overByAud)} '
              'over its $period budget. Nothing is blocked.'
        : '${formatAud(budget.remainingAud)} remaining in '
              '${budget.category.label} this ${budget.period.noun}.';

    return Scaffold(
      appBar: AppBar(title: const Text('Saved')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: <Widget>[
            Icon(Icons.check_circle_outline, size: 56, color: colors.primary),
            const SizedBox(height: 16),
            Text(
              '${formatAud(expense.amountAud)} added to '
              '${expense.category.label}',
              textAlign: TextAlign.center,
              style: text.headlineSmall,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (budget.hasBudget) ...<Widget>[
                      Text(
                        'Remaining in ${expense.category.label} this '
                        '${budget.period.noun}',
                        style: text.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        formatAud(budget.remainingAud.abs()),
                        style: text.headlineMedium?.copyWith(
                          color: budget.isOverLimit
                              ? colors.error
                              : colors.primary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      BudgetBar(budget: budget),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      effect,
                      style: text.bodyMedium?.copyWith(
                        color: budget.isOverLimit ? colors.error : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () {
                final MoneePocketStore store = MoneePocketScope.read(context);
                showBriefMessage(
                  context,
                  'Saved - ${formatAud(expense.amountAud)} in '
                  '${expense.category.label}',
                  actionLabel: 'Undo',
                  onAction: () => store.deleteExpense(expense),
                );
                _close(context);
              },
              child: const Text('Done'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => context.pushReplacement('/add'),
              child: const Text('Add more spending'),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------
// SCREEN - PAYMENT DETAILS (/expense/:id)
//
// One payment looked up by the id in the URL; pen icon edits, button deletes.
// ------------------------------------------------------------

class ExpenseDetailScreen extends StatefulWidget {  // one payment found by the id in the URL
  const ExpenseDetailScreen({super.key, required this.expenseId});

  final String expenseId;

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {  // keeps the payment on screen while it closes
  Expense? _shown;

  @override
  Widget build(BuildContext context) {
    _shown =
        MoneePocketScope.of(context).expenseById(widget.expenseId) ?? _shown;
    final Expense? expense = _shown;
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    if (expense == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Payment')),
        body: const Center(child: Text('This payment no longer exists.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Edit this payment',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/expense/${expense.id}/edit'),
          ),
        ],
      ),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Row(
              children: <Widget>[
                CategoryAvatar(category: expense.category, radius: 28),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        formatAud(expense.amountAud),
                        style: text.displaySmall?.copyWith(
                          color: colors.tertiary,
                        ),
                      ),
                      Text(expense.description, style: text.titleMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: Icon(expense.category.icon),
                    title: const Text('Category'),
                    subtitle: Text(expense.category.label),
                  ),
                  ListTile(
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('Date'),
                    subtitle: Text(
                      '${formatWeekday(expense.date.weekday)} '
                      '${formatDayMonth(expense.date)} ${expense.date.year}',
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('Receipt'),
                    subtitle: Text(expense.receiptName ?? 'No receipt saved'),
                  ),
                  if (expense.isShared)
                    const ListTile(
                      leading: Icon(Icons.group_outlined),
                      title: Text('Shared bill'),
                      subtitle: Text('Your agreed share of a household bill'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () {
                deleteExpenseWithUndo(context, expense);
                context.pop();
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete this payment'),
            ),
          ],
        ),
      ),
    );
  }
}
