package org.esotericcode.reversi.gameengine.security

import play.api.mvc.{ActionBuilder, ActionRefiner, Request, Result, Results, WrappedRequest}
import play.api.Configuration
import scala.concurrent.{ExecutionContext, Future}
import play.api.Logger

import javax.inject.{Inject, Singleton}

/**
 * Custom request type that includes API key validation
 */
case class ApiKeyRequest[A](request: Request[A], apiKey: String) extends WrappedRequest[A](request)

/**
 * Verifies the x-api-key header against the configured API key
 * Returns 401 Unauthorized if key is invalid
 * Returns 403 Forbidden if header is missing
 */
@Singleton
class ApiKeyRefiner @Inject()(config: Configuration)(implicit ec: ExecutionContext)
  extends ActionRefiner[Request, ApiKeyRequest] {

  private val logger = Logger(this.getClass)
  private val expectedApiKey = config.get[String]("api.key")

  def executionContext: ExecutionContext = ec

  override def refine[A](request: Request[A]): Future[Either[Result, ApiKeyRequest[A]]] = {
    val providedKey = request.headers.get("x-api-key")
    
    providedKey match {
      case Some(key) if key == expectedApiKey =>
        logger.debug("API key validation successful")
        Future.successful(Right(ApiKeyRequest(request, key)))
      case Some(_) =>
        logger.warn(s"Invalid API key provided from ${request.remoteAddress}")
        Future.successful(Left(Results.Unauthorized("""{"error": "invalid api key"}""")))
      case None =>
        logger.warn(s"Missing API key header from ${request.remoteAddress}")
        Future.successful(Left(Results.Forbidden("""{"error": "missing header x-api-key"}""")))
    }
  }
}

/**
 * Combines BodyParsers and ApiKeyRefiner to create a protected action builder
 */
@Singleton
class ApiKeyAction @Inject()(
  val parser: play.api.mvc.BodyParsers.Default,
  val refiner: ApiKeyRefiner
)(implicit ec: ExecutionContext) extends ActionBuilder[ApiKeyRequest, play.api.mvc.AnyContent] {

  def executionContext: ExecutionContext = ec

  override def invokeBlock[A](request: Request[A], block: ApiKeyRequest[A] => Future[Result]): Future[Result] = {
    refiner.refine(request).flatMap {
      case Right(apiKeyRequest) => block(apiKeyRequest)
      case Left(result) => Future.successful(result)
    }
  }
}

