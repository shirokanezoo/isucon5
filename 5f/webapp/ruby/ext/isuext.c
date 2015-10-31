#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/version.h>

VALUE rb_mIsuext;

static VALUE
m_test(VALUE self)
{
  return rb_str_new2("test");
}

void
Init_isuext(void)
{
  rb_mIsuext = rb_define_module("Isuext");
  rb_define_singleton_method(rb_mIsuext, "test", RUBY_METHOD_FUNC(m_test), 0);
}
