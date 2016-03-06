class ReviewController < ApplicationController
  before_action :authenticate_user!

  def index
    if params[:reason].present? and reason = Reason.find(params[:reason])
      @posts = reason.posts
    else
      @posts = Post.all
    end

    @posts = @posts.includes(:reasons).includes(:feedbacks).where( :feedbacks => { :post_id => nil }).order('created_at DESC').paginate(:page => params[:page], :per_page => 100)
    @sites = Site.where(:id => @posts.map(&:site_id))
  end

  def add_feedback
    not_found unless ["tp", "fp", "naa"].include? params[:feedback_type]

    post = Post.find(params[:post_id])
    if post.nil? or post.feedbacks.present?
      render :text => "Post doesn't exist or already has feedback", :status => :conflict
      return
    end

    f = Feedback.new
    f.user = current_user
    f.post = post
    f.feedback_type = params[:feedback_type]
    f.save!

    post.reasons.each do |reason|
      expire_fragment(reason)
    end 

    render :nothing => true, :status => 200
  end
end
