// Minimal MQL5 API stand-in used only to syntax/type-check .mq5 code with g++.
// Signatures and return types follow the MQL5 reference for the functions used by v10.
#pragma once
#include <string>
#include <vector>
#include <cstring>
#include <cfloat>
#include <climits>

typedef std::string     string;
typedef unsigned long   ulong;
typedef unsigned int    uint;
typedef unsigned short  ushort;
typedef unsigned char   uchar;
typedef long            datetime;
typedef unsigned int    color;

template<typename T> struct MqlArray
  {
   std::vector<T> v;
   bool series = false;
   T &operator[](int i) { return v[(size_t)i]; }
   const T &operator[](int i) const { return v[(size_t)i]; }
  };

struct MqlTick
  {
   datetime time;
   double   bid;
   double   ask;
   double   last;
   ulong    volume;
   long     time_msc;
   uint     flags;
   double   volume_real;
  };

struct MqlDateTime
  {
   int year, mon, day, hour, min, sec, day_of_week, day_of_year;
  };

enum ENUM_TIMEFRAMES { PERIOD_CURRENT = 0, PERIOD_M1 = 1, PERIOD_M5 = 5 };
enum ENUM_MA_METHOD { MODE_SMA, MODE_EMA, MODE_SMMA, MODE_LWMA };
enum ENUM_APPLIED_PRICE { PRICE_CLOSE = 1 };
enum ENUM_SYMBOL_INFO_DOUBLE { SYMBOL_POINT, SYMBOL_ASK, SYMBOL_BID, SYMBOL_VOLUME_MIN, SYMBOL_VOLUME_MAX,
                               SYMBOL_VOLUME_STEP, SYMBOL_TRADE_TICK_SIZE, SYMBOL_TRADE_TICK_VALUE, SYMBOL_TRADE_CONTRACT_SIZE, SYMBOL_MARGIN_HEDGED, SYMBOL_MARGIN_INITIAL };
enum ENUM_SYMBOL_INFO_INTEGER { SYMBOL_MARGIN_HEDGED_USE_LEG, SYMBOL_FILLING_MODE, SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_MODE, SYMBOL_TRADE_EXEMODE,
                                SYMBOL_DIGITS, SYMBOL_EXPIRATION_MODE };
const int SYMBOL_EXPIRATION_GTC = 1;
enum ENUM_SYMBOL_TRADE_MODE { SYMBOL_TRADE_MODE_DISABLED, SYMBOL_TRADE_MODE_LONGONLY, SYMBOL_TRADE_MODE_SHORTONLY,
                              SYMBOL_TRADE_MODE_CLOSEONLY, SYMBOL_TRADE_MODE_FULL };
enum ENUM_SYMBOL_TRADE_EXECUTION { SYMBOL_TRADE_EXECUTION_REQUEST, SYMBOL_TRADE_EXECUTION_INSTANT,
                                   SYMBOL_TRADE_EXECUTION_MARKET, SYMBOL_TRADE_EXECUTION_EXCHANGE };
const int SYMBOL_FILLING_FOK = 1;
const int SYMBOL_FILLING_IOC = 2;
enum ENUM_ACCOUNT_INFO_STRING { ACCOUNT_CURRENCY };
enum ENUM_ACCOUNT_INFO_DOUBLE { ACCOUNT_EQUITY, ACCOUNT_BALANCE, ACCOUNT_MARGIN, ACCOUNT_MARGIN_FREE, ACCOUNT_MARGIN_LEVEL };
enum ENUM_ACCOUNT_INFO_INTEGER { ACCOUNT_MARGIN_MODE, ACCOUNT_LOGIN, ACCOUNT_TRADE_MODE, ACCOUNT_TRADE_EXPERT,
                                 ACCOUNT_TRADE_ALLOWED };
enum ENUM_ACCOUNT_MARGIN_MODE { ACCOUNT_MARGIN_MODE_RETAIL_NETTING, ACCOUNT_MARGIN_MODE_EXCHANGE,
                                ACCOUNT_MARGIN_MODE_RETAIL_HEDGING };
enum ENUM_ACCOUNT_TRADE_MODE { ACCOUNT_TRADE_MODE_DEMO, ACCOUNT_TRADE_MODE_CONTEST, ACCOUNT_TRADE_MODE_REAL };
enum ENUM_MQL_INFO_INTEGER { MQL_TESTER, MQL_VISUAL_MODE, MQL_OPTIMIZATION, MQL_TRADE_ALLOWED };
enum ENUM_TERMINAL_INFO_INTEGER { TERMINAL_TRADE_ALLOWED };
enum ENUM_ORDER_TYPE { ORDER_TYPE_BUY, ORDER_TYPE_SELL, ORDER_TYPE_BUY_LIMIT, ORDER_TYPE_SELL_LIMIT, ORDER_TYPE_BUY_STOP,
                       ORDER_TYPE_SELL_STOP };
enum ENUM_ORDER_STATE { ORDER_STATE_STARTED, ORDER_STATE_PLACED, ORDER_STATE_CANCELED, ORDER_STATE_PARTIAL,
                        ORDER_STATE_FILLED, ORDER_STATE_REJECTED, ORDER_STATE_EXPIRED };
enum ENUM_ORDER_PROPERTY_INTEGER { ORDER_TYPE, ORDER_MAGIC, ORDER_STATE, ORDER_TICKET };
enum ENUM_ORDER_PROPERTY_DOUBLE { ORDER_PRICE_OPEN, ORDER_VOLUME_CURRENT };
enum ENUM_ORDER_PROPERTY_STRING { ORDER_SYMBOL, ORDER_COMMENT };
enum ENUM_ORDER_TYPE_FILLING { ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN, ORDER_FILLING_BOC };
enum ENUM_ORDER_TYPE_TIME { ORDER_TIME_GTC, ORDER_TIME_DAY, ORDER_TIME_SPECIFIED, ORDER_TIME_SPECIFIED_DAY };
enum ENUM_TRADE_REQUEST_ACTIONS { TRADE_ACTION_DEAL = 1, TRADE_ACTION_PENDING = 5, TRADE_ACTION_SLTP = 6,
                                  TRADE_ACTION_MODIFY = 7, TRADE_ACTION_REMOVE = 8, TRADE_ACTION_CLOSE_BY = 10 };
enum ENUM_POSITION_TYPE { POSITION_TYPE_BUY, POSITION_TYPE_SELL };
enum ENUM_POSITION_PROPERTY_INTEGER { POSITION_TYPE, POSITION_MAGIC, POSITION_IDENTIFIER, POSITION_TICKET, POSITION_TIME,
                                      POSITION_TIME_MSC };
enum ENUM_POSITION_PROPERTY_DOUBLE { POSITION_VOLUME, POSITION_PRICE_OPEN, POSITION_SL, POSITION_TP, POSITION_PROFIT,
                                     POSITION_SWAP };
enum ENUM_POSITION_PROPERTY_STRING { POSITION_SYMBOL, POSITION_COMMENT };
enum ENUM_DEAL_PROPERTY_INTEGER { DEAL_MAGIC, DEAL_ENTRY, DEAL_TYPE, DEAL_TIME, DEAL_POSITION_ID, DEAL_ORDER, DEAL_REASON,
                                  DEAL_TIME_MSC };
enum ENUM_DEAL_PROPERTY_DOUBLE { DEAL_PROFIT, DEAL_COMMISSION, DEAL_SWAP, DEAL_FEE, DEAL_VOLUME, DEAL_PRICE };
enum ENUM_DEAL_PROPERTY_STRING { DEAL_SYMBOL, DEAL_COMMENT };
enum ENUM_DEAL_ENTRY { DEAL_ENTRY_IN, DEAL_ENTRY_OUT, DEAL_ENTRY_INOUT, DEAL_ENTRY_OUT_BY };
enum ENUM_DEAL_TYPE { DEAL_TYPE_BUY, DEAL_TYPE_SELL, DEAL_TYPE_BALANCE };
enum ENUM_DEAL_REASON { DEAL_REASON_CLIENT, DEAL_REASON_MOBILE, DEAL_REASON_WEB, DEAL_REASON_EXPERT, DEAL_REASON_SL,
                        DEAL_REASON_TP, DEAL_REASON_SO, DEAL_REASON_ROLLOVER, DEAL_REASON_VMARGIN, DEAL_REASON_SPLIT };
enum ENUM_TRADE_TRANSACTION_TYPE { TRADE_TRANSACTION_ORDER_ADD, TRADE_TRANSACTION_DEAL_ADD, TRADE_TRANSACTION_POSITION, TRADE_TRANSACTION_REQUEST };
enum ENUM_CALENDAR_EVENT_IMPORTANCE { CALENDAR_IMPORTANCE_NONE, CALENDAR_IMPORTANCE_LOW, CALENDAR_IMPORTANCE_MODERATE,
                                      CALENDAR_IMPORTANCE_HIGH };
enum ENUM_OBJECT { OBJ_TEXT, OBJ_LABEL, OBJ_RECTANGLE_LABEL };
enum ENUM_OBJECT_PROPERTY_INTEGER { OBJPROP_CORNER, OBJPROP_XDISTANCE, OBJPROP_YDISTANCE, OBJPROP_XSIZE,
                                    OBJPROP_YSIZE, OBJPROP_BGCOLOR, OBJPROP_BORDER_TYPE, OBJPROP_COLOR,
                                    OBJPROP_BACK, OBJPROP_SELECTABLE, OBJPROP_HIDDEN, OBJPROP_FONTSIZE,
                                    OBJPROP_ANCHOR };
enum ENUM_OBJECT_PROPERTY_STRING { OBJPROP_TEXT, OBJPROP_FONT, OBJPROP_TOOLTIP };
enum ENUM_BASE_CORNER { CORNER_LEFT_UPPER };
enum ENUM_BORDER_TYPE { BORDER_FLAT };
enum ENUM_ANCHOR_POINT { ANCHOR_LEFT_LOWER };
enum ENUM_INIT_RETCODE { INIT_SUCCEEDED = 0, INIT_FAILED = 1, INIT_PARAMETERS_INCORRECT = 2 };

const uint TRADE_RETCODE_REQUOTE = 10004, TRADE_RETCODE_REJECT = 10006, TRADE_RETCODE_CANCEL = 10007,
           TRADE_RETCODE_PLACED = 10008, TRADE_RETCODE_DONE = 10009, TRADE_RETCODE_DONE_PARTIAL = 10010,
           TRADE_RETCODE_ERROR = 10011, TRADE_RETCODE_TIMEOUT = 10012, TRADE_RETCODE_INVALID = 10013,
           TRADE_RETCODE_INVALID_VOLUME = 10014, TRADE_RETCODE_INVALID_PRICE = 10015,
           TRADE_RETCODE_INVALID_STOPS = 10016, TRADE_RETCODE_TRADE_DISABLED = 10017,
           TRADE_RETCODE_MARKET_CLOSED = 10018, TRADE_RETCODE_NO_MONEY = 10019,
           TRADE_RETCODE_PRICE_CHANGED = 10020, TRADE_RETCODE_PRICE_OFF = 10021,
           TRADE_RETCODE_TOO_MANY_REQUESTS = 10024, TRADE_RETCODE_NO_CHANGES = 10025,
           TRADE_RETCODE_SERVER_DISABLES_AT = 10026, TRADE_RETCODE_CLIENT_DISABLES_AT = 10027,
           TRADE_RETCODE_FROZEN = 10029, TRADE_RETCODE_INVALID_FILL = 10030, TRADE_RETCODE_CONNECTION = 10031,
           TRADE_RETCODE_LIMIT_VOLUME = 10034, TRADE_RETCODE_POSITION_CLOSED = 10036,
           TRADE_RETCODE_LIMIT_POSITIONS = 10040;

struct MqlTradeRequest
  {
   ENUM_TRADE_REQUEST_ACTIONS action;
   ulong                      magic;
   ulong                      order;
   string                     symbol;
   double                     volume;
   double                     price;
   double                     stoplimit;
   double                     sl;
   double                     tp;
   ulong                      deviation;
   ENUM_ORDER_TYPE            type;
   ENUM_ORDER_TYPE_FILLING    type_filling;
   ENUM_ORDER_TYPE_TIME       type_time;
   datetime                   expiration;
   string                     comment;
   ulong                      position;
   ulong                      position_by;
  };

struct MqlTradeResult
  {
   uint   retcode;
   ulong  deal;
   ulong  order;
   double volume;
   double price;
   double bid;
   double ask;
   string comment;
   uint   request_id;
   int    retcode_external;
  };

struct MqlTradeTransaction
  {
   ulong                       deal;
   ulong                       order;
   string                      symbol;
   ENUM_TRADE_TRANSACTION_TYPE type;
   ulong                       position;
  };

struct MqlCalendarValue
  {
   ulong    id;
   ulong    event_id;
   datetime time;
   datetime period;
   int      revision;
   long     actual_value;
   long     prev_value;
   long     revised_prev_value;
   long     forecast_value;
  };

struct MqlCalendarEvent
  {
   ulong                          id;
   ENUM_CALENDAR_EVENT_IMPORTANCE importance;
   string                         name;
  };

const int    INVALID_HANDLE = -1;
const double EMPTY_VALUE    = DBL_MAX;
const int    TIME_DATE      = 1;
const int    TIME_MINUTES   = 2;
const int    TIME_SECONDS   = 4;
extern int   _Digits;
extern double _Point;

const color clrNONE = 0xFFFFFFFF, clrKhaki = 1, clrLime = 2, clrTomato = 3, clrDeepSkyBlue = 4,
            clrSilver = 5, clrGray = 6, clrOrange = 7, clrWhite = 8;

extern string          _Symbol;
extern ENUM_TIMEFRAMES _Period;

template<typename... A> void   Print(A... a);
template<typename... A> string StringFormat(const string &fmt, A... a);
template<typename T> bool ArraySetAsSeries(MqlArray<T> &a, bool flag);
template<typename T, size_t N, typename V> int ArrayInitialize(T (&a)[N], V value);
template<typename T> int ArrayResize(MqlArray<T> &a, int size);
template<typename T> int ArraySize(const MqlArray<T> &a);
template<typename T> void ZeroMemory(T &x);
void ZeroMemory(MqlTradeRequest &x);   // structs with strings: never memset
void ZeroMemory(MqlTradeResult &x);
template<typename E> string EnumToString(E value);

int      iATR(const string &symbol, ENUM_TIMEFRAMES tf, int period);
int      iADX(const string &symbol, ENUM_TIMEFRAMES tf, int period);
int      iRSI(const string &symbol, ENUM_TIMEFRAMES tf, int period, int price);
int      iMA(const string &symbol, ENUM_TIMEFRAMES tf, int period, int shift, ENUM_MA_METHOD method, int price);
int      iBands(const string &symbol, ENUM_TIMEFRAMES tf, int period, int shift, double deviation, int price);
int      CopyBuffer(int handle, int buffer, int start, int count, MqlArray<double> &buf);
int      CopyClose(const string &symbol, ENUM_TIMEFRAMES tf, int start, int count, MqlArray<double> &buf);
int      CopyHigh(const string &symbol, ENUM_TIMEFRAMES tf, int start, int count, MqlArray<double> &buf);
int      CopyLow(const string &symbol, ENUM_TIMEFRAMES tf, int start, int count, MqlArray<double> &buf);
int      CopyTime(const string &symbol, ENUM_TIMEFRAMES tf, int start, int count, MqlArray<datetime> &buf);
datetime iTime(const string &symbol, ENUM_TIMEFRAMES tf, int shift);
bool     IndicatorRelease(int handle);
bool     SymbolInfoTick(const string &symbol, MqlTick &tick);
double   SymbolInfoDouble(const string &symbol, ENUM_SYMBOL_INFO_DOUBLE prop);
long     SymbolInfoInteger(const string &symbol, ENUM_SYMBOL_INFO_INTEGER prop);
string   AccountInfoString(ENUM_ACCOUNT_INFO_STRING prop);
double   AccountInfoDouble(ENUM_ACCOUNT_INFO_DOUBLE prop);
long     AccountInfoInteger(ENUM_ACCOUNT_INFO_INTEGER prop);
int      MQLInfoInteger(ENUM_MQL_INFO_INTEGER prop);
int      TerminalInfoInteger(ENUM_TERMINAL_INFO_INTEGER prop);
bool     OrderCalcProfit(ENUM_ORDER_TYPE type, const string &symbol, double volume, double open, double close, double &profit);
bool     OrderCalcMargin(ENUM_ORDER_TYPE type, const string &symbol, double volume, double price, double &margin);
// [[nodiscard]] mirrors MetaEditor warning 83 ("return value of 'OrderSend' should be checked")
[[nodiscard]] bool OrderSend(const MqlTradeRequest &req, MqlTradeResult &res);
[[nodiscard]] bool OrderSendAsync(const MqlTradeRequest &req, MqlTradeResult &res);
int      iBarShift(const string &symbol, ENUM_TIMEFRAMES tf, datetime time, bool exact = false);
datetime GlobalVariableSet(const string &name, double value);
double   GlobalVariableGet(const string &name);
bool     GlobalVariableCheck(const string &name);
bool     GlobalVariableGet(const string &name, double &value);
void     GlobalVariablesFlush();
bool     GlobalVariableDel(const string &name);
const int FILE_READ = 1, FILE_WRITE = 2, FILE_CSV = 8, FILE_ANSI = 32, FILE_SHARE_READ = 128, FILE_COMMON = 4096;
// SEEK_END comes from the C library (same value as MQL5)
int      FileOpen(const string &name, int flags, short delimiter);
template<typename... A> uint FileWrite(int handle, A... a);
void     FileClose(int handle);
bool     FileSeek(int handle, long offset, int origin);
ulong    FileSize(int handle);
int      StringReplace(string &s, const string &find, const string &repl);
string   StringSubstr(const string &s, int start, int length = -1);
int      PositionsTotal();
ulong    PositionGetTicket(int index);
bool     PositionSelectByTicket(ulong ticket);
long     PositionGetInteger(ENUM_POSITION_PROPERTY_INTEGER prop);
double   PositionGetDouble(ENUM_POSITION_PROPERTY_DOUBLE prop);
string   PositionGetString(ENUM_POSITION_PROPERTY_STRING prop);
bool     HistorySelect(datetime from, datetime to);
bool     HistorySelectByPosition(long position_id);
bool     HistoryDealSelect(ulong ticket);
int      OrdersTotal();
ulong    OrderGetTicket(int index);
bool     OrderSelect(ulong ticket);
long     OrderGetInteger(ENUM_ORDER_PROPERTY_INTEGER prop);
double   OrderGetDouble(ENUM_ORDER_PROPERTY_DOUBLE prop);
string   OrderGetString(ENUM_ORDER_PROPERTY_STRING prop);
bool     HistoryOrderSelect(ulong ticket);
long     HistoryOrderGetInteger(ulong ticket, ENUM_ORDER_PROPERTY_INTEGER prop);
int      HistoryDealsTotal();
ulong    HistoryDealGetTicket(int index);
long     HistoryDealGetInteger(ulong ticket, ENUM_DEAL_PROPERTY_INTEGER prop);
double   HistoryDealGetDouble(ulong ticket, ENUM_DEAL_PROPERTY_DOUBLE prop);
string   HistoryDealGetString(ulong ticket, ENUM_DEAL_PROPERTY_STRING prop);
int      CalendarValueHistory(MqlArray<MqlCalendarValue> &values, datetime from, datetime to, const char *country, const string &currency);
bool     CalendarEventById(ulong event_id, MqlCalendarEvent &event);
datetime TimeCurrent();
datetime TimeTradeServer();
bool     TimeToStruct(datetime t, MqlDateTime &s);
string   TimeToString(datetime t, int mode = TIME_DATE | TIME_MINUTES);
string   IntegerToString(long v, int len = 0, ushort fill = ' ');
string   DoubleToString(double v, int digits = 8);
int      StringSplit(const string &s, ushort sep, MqlArray<string> &out);
ushort   StringGetCharacter(const string &s, int pos);
long     StringToInteger(const string &s);
int      StringTrimLeft(string &s);
int      StringTrimRight(string &s);
int      StringLen(const string &s);
int      StringFind(const string &s, const string &what, int start = 0);
double   MathAbs(double v);
double   MathMax(double a, double b);
double   MathMin(double a, double b);
double   MathFloor(double v);
double   MathRound(double v);
double   NormalizeDouble(double v, int digits);
bool     ObjectCreate(long chart, const string &name, ENUM_OBJECT type, int sub, datetime t, double price);
int      ObjectFind(long chart, const string &name);
bool     ObjectSetInteger(long chart, const string &name, ENUM_OBJECT_PROPERTY_INTEGER prop, long value);
bool     ObjectSetString(long chart, const string &name, ENUM_OBJECT_PROPERTY_STRING prop, const string &value);
bool     ObjectDelete(long chart, const string &name);
int      ObjectsDeleteAll(long chart, const string &prefix, int sub = -1, int type = -1);
void     ChartRedraw(long chart = 0);
bool     EventSetMillisecondTimer(int ms);
bool     EventSetTimer(int sec);
void     EventKillTimer();
ulong    GetMicrosecondCount();
int      GetLastError();
void     ResetLastError();
