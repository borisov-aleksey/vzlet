$(document).ready(function() {
  $(".m_links_c li").mouseover(function(event) {
    $(this).addClass("hover");
  }).mouseout(function(event) {
    $(this).removeClass("hover");
  });
});
