// Check of the v14 news window code (P3, build 1.1), run against the translated EA (v14_check.cpp).
// Only the new functions are called; everything else is left unlinked.
#include <cstdio>
#include <cstring>
#include <ctime>
#include <sstream>
#include "v14_check.cpp"

extern const double          InpLots          = 0.01;
extern const int             InpMaxTrades     = 2;
extern const double          InpHarvestNet    = 4.00;
extern const double          InpHedgeDistance = 8.00;
extern const double          InpHedgeMult     = 2.0;
extern const double          InpTrade3Mult    = 3.0;
extern const double          InpBasketTarget  = 1.00;
extern const double          InpHardStop      = 30.00;
extern const V14_ENTRY       InpEntryMode     = V14_ENTRY_LIMIT;
extern const ENUM_TIMEFRAMES InpTrendTF       = PERIOD_M5;
extern const int             InpEmaFast       = 20;
extern const int             InpEmaSlow       = 50;
extern const int             InpAdxPeriod     = 14;
extern const double          InpAdxMin        = 15.0;
extern const ENUM_TIMEFRAMES InpEntryTF       = PERIOD_M5;
extern const int             InpPullEma       = 20;
extern const int             InpRsiPeriod     = 14;
extern const double          InpRsiMax        = 70.0;
extern const double          InpMaxSpread     = 1.00;
extern const bool            InpNewsFilter    = true;
extern const string          InpNewsStart     = "15:00";
extern const string          InpNewsEnd       = "15:45";
extern const long            InpMagic         = 140001;

//--- the shim functions the new code uses
static std::vector<std::string> g_log;
static void Cat(std::ostringstream &) {}
template<typename H, typename... R> static void Cat(std::ostringstream &o, H h, R... r) { o << h; Cat(o, r...); }
template<typename... A> void Print(A... a) { std::ostringstream o; Cat(o, a...); g_log.push_back(o.str()); }
static const char *Arg(const string &s) { return s.c_str(); }
template<typename T> static T Arg(T v) { return v; }
template<typename... A> string StringFormat(const string &fmt, A... a) { char b[2048]; std::snprintf(b, sizeof(b), fmt.c_str(), Arg(a)...); return b; }
bool TimeToStruct(datetime t, MqlDateTime &s)
  {
   time_t tt = (time_t)t; struct tm g; gmtime_r(&tt, &g);
   s.year = g.tm_year + 1900; s.mon = g.tm_mon + 1; s.day = g.tm_mday; s.hour = g.tm_hour; s.min = g.tm_min; s.sec = g.tm_sec;
   s.day_of_week = g.tm_wday; s.day_of_year = g.tm_yday;
   return true;
  }
int StringSplit(const string &s, ushort sep, MqlArray<string> &out)
  {
   out.v.clear(); string cur;
   for(char ch : s) { if((ushort)ch == sep) { out.v.push_back(cur); cur.clear(); } else cur += ch; }
   out.v.push_back(cur);
   return (int)out.v.size();
  }
ushort StringGetCharacter(const string &s, int pos) { return (pos >= 0 && pos < (int)s.size()) ? (ushort)(unsigned char)s[(size_t)pos] : 0; }
long   StringToInteger(const string &s) { return std::atol(s.c_str()); }
int    StringTrimLeft(string &s) { size_t n = s.find_first_not_of(' '); if(n == string::npos) { int k = (int)s.size(); s.clear(); return k; } s.erase(0, n); return (int)n; }
int    StringTrimRight(string &s) { size_t n = s.find_last_not_of(' '); if(n == string::npos) { int k = (int)s.size(); s.clear(); return k; } int k = (int)(s.size() - (n + 1)); s.erase(n + 1); return k; }
int    StringLen(const string &s) { return (int)s.size(); }
string StringSubstr(const string &s, int start, int len) { return s.substr((size_t)start, (size_t)len); }
string IntegerToString(long v, int, ushort) { return std::to_string(v); }

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, what) do { if(cond) g_pass++; else { std::printf("FAIL: %s\n", what); g_fail++; } } while(0)

static long Msc(int y, int mo, int d, int h, int mi, int s)
  {
   struct tm g; std::memset(&g, 0, sizeof(g));
   g.tm_year = y - 1900; g.tm_mon = mo - 1; g.tm_mday = d; g.tm_hour = h; g.tm_min = mi; g.tm_sec = s;
   return (long)timegm(&g) * 1000 + 999;   // last millisecond of that second
  }

int main()
  {
   //--- the HH:MM parser
   struct { const char *in; int want; } p[] = {
      {"15:00", 900}, {"15:45", 945}, {" 9:05 ", 545}, {"00:00", 0}, {"23:59", 1439}, {"7:5", 425},
      {"24:00", -1}, {"15:60", -1}, {"1500", -1}, {"15:0a", -1}, {"", -1}, {"   ", -1}, {"15:00:00", -1},
      {":30", -1}, {"15:", -1}, {"123:00", -1}, {"-1:30", -1}, {"15.30", -1}, {"+1:30", -1},
      //--- build 1.1.1: the optimizer passes string inputs with quotes
      {"\"15:00\"", 900}, {"\"15:45\"", 945}, {"'15:00'", 900}, {" \"15:00\" ", 900}, {"\t15:00\r\n", 900},
      {"\"\"15:00\"\"", 900}, {"\xA0" "15:00", 900}, {"\"\"", -1}, {"\"15:60\"", -1}, {"\"15\":00", -1}, {"\"1500\"", -1} };
   for(auto &c : p)
     {
      int got = MinutesOf(c.in);
      char w[96]; std::snprintf(w, sizeof(w), "MinutesOf(\"%s\") = %d, want %d", c.in, got, c.want);
      CHECK(got == c.want, w);
     }
   CHECK(RawTimeText("\"15:00\"") == "[\"15:00\"] (7 chars: 34 49 53 58 48 48 34)", "RawTimeText");
   CHECK(ClockText(900) == "15:00" && ClockText(945) == "15:45" && ClockText(545) == "09:05" && ClockText(0) == "00:00", "ClockText");

   //--- the window: 15:00 to 15:45, Monday to Friday (2026-09-07 is a Monday)
   g_newsStart = MinutesOf(InpNewsStart);
   g_newsEnd   = MinutesOf(InpNewsEnd);
   struct { int d, h, mi, s; bool want; const char *what; } w[] = {
      {7, 14, 59, 59, false, "Mon 14:59:59"}, {7, 15, 0, 0, true, "Mon 15:00:00"}, {7, 15, 30, 0, true, "Mon 15:30:00"},
      {7, 15, 44, 59, true, "Mon 15:44:59"}, {7, 15, 45, 0, false, "Mon 15:45:00"}, {7, 3, 0, 0, false, "Mon 03:00"},
      {11, 15, 10, 0, true, "Fri 15:10"}, {11, 21, 30, 0, false, "Fri 21:30 (no Friday rule)"}, {11, 23, 50, 0, false, "Fri 23:50"},
      {12, 15, 10, 0, false, "Sat 15:10"}, {13, 15, 10, 0, false, "Sun 15:10"}, {14, 15, 20, 0, true, "Mon 14 Sep 15:20"} };
   for(auto &c : w)
     {
      g_nowMsc = Msc(2026, 9, c.d, c.h, c.mi, c.s);
      CHECK(NewsWindowNow() == c.want, c.what);
     }

   //--- one journal line per window start, none at the end
   g_inNews = false; g_basket = false; g_limitTicket = 0; g_log.clear();
   long seq[] = { Msc(2026, 9, 7, 14, 59, 0), Msc(2026, 9, 7, 15, 0, 0), Msc(2026, 9, 7, 15, 1, 0), Msc(2026, 9, 7, 15, 44, 59),
                  Msc(2026, 9, 7, 15, 45, 0), Msc(2026, 9, 7, 16, 0, 0), Msc(2026, 9, 8, 15, 2, 0) };
   bool inAfter[] = { false, true, true, true, false, false, true };
   for(int k = 0; k < 7; k++)
     {
      if(k == 6) g_limitTicket = 77;      // a limit order waiting at the second window start
      g_nowMsc = seq[k];
      UpdateNewsWindow();
      char t[64]; std::snprintf(t, sizeof(t), "g_inNews after step %d", k);
      CHECK(g_inNews == inAfter[k], t);
     }
   CHECK(g_log.size() == 2, "two journal lines (one per window)");
   for(auto &l : g_log) std::printf("journal: %s\n", l.c_str());

   //--- filter off: never in the window
   //--- (InpNewsFilter is a constant here, so this is checked through the same code path with an empty window)
   g_newsStart = 0; g_newsEnd = 0; g_nowMsc = Msc(2026, 9, 7, 15, 10, 0);
   CHECK(!NewsWindowNow(), "an empty window never blocks");

   std::printf("passed %d, failed %d\n", g_pass, g_fail);
   return g_fail == 0 ? 0 : 1;
  }
