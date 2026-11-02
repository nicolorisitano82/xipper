/* Writer (phase 2): placeholder until implemented. */
#include "internal.h"

int xiz_writer_create(xiz_writer **out, const char *path, const xiz_writer_options *opt, int overwrite, xiz_error *err) {
    (void)out; (void)path; (void)opt; (void)overwrite;
    return FAIL(XIZ_E_UNSUPPORTED, "writer not implemented");
}
int xiz_writer_append(xiz_writer **out, const char *path, const xiz_writer_options *opt, xiz_error *err) {
    (void)out; (void)path; (void)opt;
    return FAIL(XIZ_E_UNSUPPORTED, "writer not implemented");
}
int xiz_writer_add_data(xiz_writer *w, const char *path, const void *data, size_t len, const xiz_entry_meta *meta, xiz_error *err) {
    (void)w; (void)path; (void)data; (void)len; (void)meta; return FAIL(XIZ_E_UNSUPPORTED, "writer");
}
int xiz_writer_add_file(xiz_writer *w, const char *path, const char *disk_path, const xiz_entry_meta *meta, xiz_error *err) {
    (void)w; (void)path; (void)disk_path; (void)meta; return FAIL(XIZ_E_UNSUPPORTED, "writer");
}
int xiz_writer_add_directory(xiz_writer *w, const char *path, const xiz_entry_meta *meta, xiz_error *err) {
    (void)w; (void)path; (void)meta; return FAIL(XIZ_E_UNSUPPORTED, "writer");
}
int xiz_writer_add_symlink(xiz_writer *w, const char *path, const char *target, const xiz_entry_meta *meta, xiz_error *err) {
    (void)w; (void)path; (void)target; (void)meta; return FAIL(XIZ_E_UNSUPPORTED, "writer");
}
int xiz_writer_add_tree(xiz_writer *w, const char *path, const char *disk_path, xiz_error *err) {
    (void)w; (void)path; (void)disk_path; return FAIL(XIZ_E_UNSUPPORTED, "writer");
}
int xiz_writer_remove(xiz_writer *w, const char *path, xiz_error *err) { (void)w; (void)path; return FAIL(XIZ_E_UNSUPPORTED, "writer"); }
int xiz_writer_finish(xiz_writer *w, xiz_error *err) { (void)w; return FAIL(XIZ_E_UNSUPPORTED, "writer"); }
void xiz_writer_abort(xiz_writer *w) { (void)w; }
