#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void){
  FILE *f = fopen("/Users/keovi/Documents/dshSpace/wechat_two/lab2/result.txt","w");
  if(!f) return 1;
  const char *h = getenv("CFFIXED_USER_HOME");
  const char *t = getenv("WXMULTI_TEST");
  fprintf(f, "CFFIXED_USER_HOME=%s\n", h ? h : "(nil)");
  fprintf(f, "WXMULTI_TEST=%s\n", t ? t : "(nil)");
  fprintf(f, "HOME=%s\n", getenv("HOME") ? getenv("HOME") : "(nil)");
  fprintf(f, "pid=%d\n", getpid());
  fclose(f);
  sleep(1);
  return 0;
}
