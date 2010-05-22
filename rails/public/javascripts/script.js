$(document).ready(function() {
  $(".m_links_c li").mouseover(function(event) {
    $(this).addClass("hover");
  }).mouseout(function(event) {
    $(this).removeClass("hover");
  });



  var label = $(".search label");
  $(".search input").val("");

  function hideLabel(input) {
    if (!input.value) {
      label.hide();
    }
  }
  $(".search input").focus(function(event) {
    label.hide();
  }).blur(function(event) {
    if (!event.currentTarget.value) {
      label.show();
    }
  }).change(function(event) {
    hideLabel(event.currentTarget);
  })

  var label2 = $(".searchB label");
  $(".searchB input").val("");

  function hideLabel(input) {
    if (!input.value) {
      label2.hide();
    }
  }
  $(".searchB input").focus(function(event) {
    label2.hide();
  }).blur(function(event) {
    if (!event.currentTarget.value) {
      label2.show();
    }
  }).change(function(event) {
    hideLabel(event.currentTarget);
  })
});
